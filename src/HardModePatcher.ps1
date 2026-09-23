param(
    [ValidateSet('Gui', 'Install', 'Restore', 'Status')]
    [string]$Action = 'Gui',
    [string]$GameDirectory
)

$ErrorActionPreference = 'Stop'

$ModVersion = '0.2.1'
$VanillaAssemblySha256 = '404C1A5077AB26C7B8456D6F8A686DB73CCDBC424A550D21F62F1E241CEAEB91'
$BaseAssemblySha256 = 'E854D8D33BF1D2AE35801AF81686085365616141759B6A2EF10ADBDD01C12168'
$VanillaBundleSha256 = '1183BF9CC81DA0341CAE865BAF17B1310F7C9992B46C8C1DD46848AF1FA6839C'
$Version010AssemblySha256 = '93CD70E11A6E3FE30EF5863600467753EC9A53CA2D7955881FDC7A003C13C1CF'
$Version010BundleSha256 = '648886D676450869BDFDE02F33A000804B42C8B7BE80556B765C548D4E9039EF'
$LocalTestAssemblySha256 = '18FCB6C05EE329F44E41D1BA3AA84266258E1A5309E1E203236C2A62DB71DDE4'
$LocalTestBundleSha256 = '753A3BCF4FFE614D2B3A24A0B1C62C042783C3032C83FD9AFA5B3C713D698D8F'
$BundleRelativePath = 'ConSim_Data\StreamingAssets\aa\9c26e1001ca50c672968ec008c8995f1.bundle'
$MetadataRelativePath = 'ConSim_Data\il2cpp_data\Metadata\global-metadata.dat'
$PatchFile = Join-Path $PSScriptRoot 'payload\GameAssembly.hmpatch'
$SettingsFile = Join-Path $PSScriptRoot 'HardEconomy-Settings.txt'
$EconomyScript = Join-Path $PSScriptRoot 'Apply-HardModeEconomyBundle.ps1'
$MilestoneScript = Join-Path $PSScriptRoot 'Update-CompanyMilestones.ps1'
$SaleScript = Join-Path $PSScriptRoot 'Apply-HardEconomySaleSettings.ps1'
$ToolDirectory = Join-Path $PSScriptRoot 'tools'
$ExpectedTools = [ordered]@{
    'AssetsTools.NET.dll' = 'E169C2C66EA2D948B42311BAB6C171A1BAC012595CEC9FCC2AEF0C92D06E9D27'
    'AssetsTools.NET.Cpp2IL.dll' = '1F8602203AC7E264D8F0F41B9CC5CA505C74630662F1D575387FE023C92BA4DF'
    'classdata.tpk' = '129E1F80F930415DB6779FE6089AFA75280CB51462BCEE812BEAB6CD81A764C6'
    'LibCpp2IL.dll' = '426082B10961E8E4844CE2AC41D88756E18E636B888C2B9ABC5F9565939BFD82'
    'WasmDisassembler.dll' = 'F487BE8716FF70164F66DC4522197AEB1A86919469FC47E98584BA0FA5D82B86'
}

function Get-Sha256 { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Assert-File { param([string]$Path) if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" } }
function Assert-GameClosed { if (Get-Process -Name 'ConSim' -ErrorAction SilentlyContinue) { throw 'Construction Simulator is running. Close the game and try again.' } }

function Prepare-TunerComponents {
    # Check every packaged component before removing any Internet Zone marker.
    foreach ($name in $ExpectedTools.Keys) {
        $file = Join-Path $ToolDirectory $name
        Assert-File $file
        if ((Get-Sha256 $file) -ne $ExpectedTools[$name]) {
            throw "Packaged tuner component '$name' failed SHA-256 validation. Extract a fresh complete Hard Economy ZIP."
        }
    }
    foreach ($name in $ExpectedTools.Keys) {
        if (-not $name.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $file = Join-Path $ToolDirectory $name
        $zone = Get-Item -LiteralPath $file -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
        if ($null -ne $zone) {
            try { Unblock-File -LiteralPath $file -ErrorAction Stop }
            catch { throw "Windows blocked verified component '$name'. Extract the ZIP locally and retry, or unblock this verified file in Properties. $($_.Exception.Message)" }
            if ($null -ne (Get-Item -LiteralPath $file -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) -or
                (Get-Sha256 $file) -ne $ExpectedTools[$name]) {
                throw "Verified tuner component '$name' could not be safely prepared."
            }
        }
    }
}

function Test-GameRoot {
    param([string]$Path)
    return (-not [string]::IsNullOrWhiteSpace($Path)) -and (Test-Path -LiteralPath (Join-Path $Path 'ConSim.exe') -PathType Leaf)
}

function Find-DefaultGameRoot {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($PSScriptRoot)
    $candidates.Add((Split-Path -Parent $PSScriptRoot))
    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1273400',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1273400'
    )) {
        try {
            $location = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop).InstallLocation
            if (-not [string]::IsNullOrWhiteSpace($location)) { $candidates.Add($location) }
        } catch {}
    }
    foreach ($candidate in $candidates) {
        if (Test-GameRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    return ''
}

function Get-Paths {
    param([string]$Root)
    $resolved = [IO.Path]::GetFullPath($Root)
    if (-not (Test-GameRoot $resolved)) { throw 'The selected folder does not contain ConSim.exe.' }
    $paths = [pscustomobject]@{
        Root = $resolved
        Assembly = Join-Path $resolved 'GameAssembly.dll'
        Bundle = Join-Path $resolved $BundleRelativePath
        Metadata = Join-Path $resolved $MetadataRelativePath
        BackupRoot = Join-Path $resolved 'HardMode_Backups'
        State = Join-Path $resolved 'HardMode_Backups\install-state.json'
    }
    foreach ($file in @($paths.Assembly, $paths.Bundle, $paths.Metadata)) { Assert-File $file }
    return $paths
}

function Read-State {
    param($Paths)
    if (-not (Test-Path -LiteralPath $Paths.State -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Paths.State -Raw | ConvertFrom-Json }
    catch { throw 'The existing Hard Economy installation record is unreadable.' }
}

function Get-Status {
    param([string]$Root)
    $paths = Get-Paths $Root
    $assemblyHash = Get-Sha256 $paths.Assembly
    $bundleHash = Get-Sha256 $paths.Bundle
    $saved = Read-State $paths
    $state = 'Unsupported'
    if ($assemblyHash -eq $VanillaAssemblySha256 -and $bundleHash -eq $VanillaBundleSha256) { $state = 'Vanilla' }
    elseif ($assemblyHash -eq $Version010AssemblySha256 -and $bundleHash -eq $Version010BundleSha256) { $state = 'Version010' }
    elseif ($assemblyHash -eq $LocalTestAssemblySha256 -and $bundleHash -eq $LocalTestBundleSha256) { $state = 'LocalTest' }
    elseif ($null -ne $saved -and [string]$saved.modVersion -in @('0.2.0', '0.2.1') -and
            $assemblyHash -eq [string]$saved.hardModeAssemblySha256 -and
            $bundleHash -eq [string]$saved.hardModeBundleSha256) { $state = 'Managed' }
    elseif ($assemblyHash -in @($VanillaAssemblySha256, $Version010AssemblySha256) -or
            $bundleHash -in @($VanillaBundleSha256, $Version010BundleSha256)) { $state = 'Mixed' }
    [pscustomobject]@{ State=$state; AssemblySha256=$assemblyHash; BundleSha256=$bundleHash; Paths=$paths; SavedState=$saved }
}

function Convert-BytesToHex { param([byte[]]$Bytes) ([BitConverter]::ToString($Bytes)).Replace('-', '') }

function Apply-BasePatch {
    param([string]$InputFile, [string]$OutputFile)
    if ((Get-Sha256 $InputFile) -ne $VanillaAssemblySha256) { throw 'The original GameAssembly.dll is not the supported Steam version.' }
    Assert-File $PatchFile
    Copy-Item -LiteralPath $InputFile -Destination $OutputFile -Force
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($PatchFile))
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'HMP1') { throw 'Native patch payload has an invalid header.' }
        $length = $reader.ReadInt64()
        $sourceHash = Convert-BytesToHex $reader.ReadBytes(32)
        $targetHash = Convert-BytesToHex $reader.ReadBytes(32)
        $count = $reader.ReadInt32()
        if ($length -ne (Get-Item $OutputFile).Length -or $sourceHash -ne $VanillaAssemblySha256 -or $targetHash -ne $BaseAssemblySha256) { throw 'Native patch payload does not belong to Hard Economy 0.2.1.' }
        if ($count -lt 1 -or $count -gt 10000) { throw 'Native patch payload contains an invalid range count.' }
        $writer = [IO.File]::Open($OutputFile, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            for ($index=0; $index -lt $count; $index++) {
                $offset=$reader.ReadInt64(); $rangeLength=$reader.ReadInt32(); $bytes=$reader.ReadBytes($rangeLength)
                if ($offset -lt 0 -or $rangeLength -lt 1 -or ($offset+$rangeLength) -gt $length -or $bytes.Length -ne $rangeLength) { throw 'Native patch payload contains an invalid range.' }
                $writer.Position=$offset; $writer.Write($bytes,0,$bytes.Length)
            }
            $writer.Flush()
        } finally { $writer.Dispose() }
    } finally { $reader.Dispose() }
    if ((Get-Sha256 $OutputFile) -ne $BaseAssemblySha256) { throw 'Generated native base failed validation.' }
}

function Get-VanillaSources {
    param($Status)
    if ($Status.State -eq 'Vanilla') { return [pscustomobject]@{ Assembly=$Status.Paths.Assembly; Bundle=$Status.Paths.Bundle; BackupDirectory='' } }
    $saved = $Status.SavedState
    if ($null -eq $saved -or [string]::IsNullOrWhiteSpace([string]$saved.backupDirectory)) { throw 'No valid original-file backup record was found. Restore through Steam before installing.' }
    $directory = [string]$saved.backupDirectory
    $assembly = Join-Path $directory 'GameAssembly.dll'
    $bundle = Join-Path $directory $BundleRelativePath
    Assert-File $assembly; Assert-File $bundle
    if ((Get-Sha256 $assembly) -ne $VanillaAssemblySha256 -or (Get-Sha256 $bundle) -ne $VanillaBundleSha256) { throw 'The recorded original-file backup is not the supported Steam version.' }
    [pscustomobject]@{ Assembly=$assembly; Bundle=$bundle; BackupDirectory=$directory }
}

function New-VanillaBackup {
    param($Paths)
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $directory=Join-Path $Paths.BackupRoot "$stamp-before-$ModVersion"
    New-Item -ItemType Directory -Path (Join-Path $directory (Split-Path -Parent $BundleRelativePath)) -Force | Out-Null
    Copy-Item $Paths.Assembly (Join-Path $directory 'GameAssembly.dll')
    Copy-Item $Paths.Bundle (Join-Path $directory $BundleRelativePath)
    if ((Get-Sha256 (Join-Path $directory 'GameAssembly.dll')) -ne $VanillaAssemblySha256 -or (Get-Sha256 (Join-Path $directory $BundleRelativePath)) -ne $VanillaBundleSha256) { throw 'Automatic original-file backup failed validation.' }
    return $directory
}

function New-OperationBackup {
    param($Paths)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $directory = Join-Path $Paths.BackupRoot "$stamp-before-apply-$ModVersion"
    New-Item -ItemType Directory -Path (Join-Path $directory (Split-Path -Parent $BundleRelativePath)) -Force | Out-Null
    Copy-Item -LiteralPath $Paths.Assembly -Destination (Join-Path $directory 'GameAssembly.dll')
    Copy-Item -LiteralPath $Paths.Bundle -Destination (Join-Path $directory $BundleRelativePath)
    $assemblyHash = Get-Sha256 $Paths.Assembly
    $bundleHash = Get-Sha256 $Paths.Bundle
    if ((Get-Sha256 (Join-Path $directory 'GameAssembly.dll')) -ne $assemblyHash -or
        (Get-Sha256 (Join-Path $directory $BundleRelativePath)) -ne $bundleHash) {
        throw 'Pre-apply rollback backup failed validation.'
    }
    return $directory
}

function Restore-OperationFiles {
    param($Paths, [string]$BackupDirectory, [string]$ExpectedAssemblyHash, [string]$ExpectedBundleHash)
    $assembly = Join-Path $BackupDirectory 'GameAssembly.dll'
    $bundle = Join-Path $BackupDirectory $BundleRelativePath
    if ((Get-Sha256 $assembly) -ne $ExpectedAssemblyHash -or (Get-Sha256 $bundle) -ne $ExpectedBundleHash) {
        throw 'Pre-apply rollback backup failed validation.'
    }
    Copy-Item -LiteralPath $assembly -Destination $Paths.Assembly -Force
    Copy-Item -LiteralPath $bundle -Destination $Paths.Bundle -Force
    if ((Get-Sha256 $Paths.Assembly) -ne $ExpectedAssemblyHash -or (Get-Sha256 $Paths.Bundle) -ne $ExpectedBundleHash) {
        throw 'Automatic rollback failed validation.'
    }
}

function Restore-VanillaFiles {
    param($Paths,[string]$BackupDirectory)
    $assembly=Join-Path $BackupDirectory 'GameAssembly.dll'; $bundle=Join-Path $BackupDirectory $BundleRelativePath
    if ((Get-Sha256 $assembly) -ne $VanillaAssemblySha256 -or (Get-Sha256 $bundle) -ne $VanillaBundleSha256) { throw 'Original-file backup failed validation.' }
    Copy-Item $assembly $Paths.Assembly -Force; Copy-Item $bundle $Paths.Bundle -Force
    if ((Get-Sha256 $Paths.Assembly) -ne $VanillaAssemblySha256 -or (Get-Sha256 $Paths.Bundle) -ne $VanillaBundleSha256) { throw 'Restored files failed validation.' }
}

function Install-HardEconomy {
    param([string]$Root)
    Assert-GameClosed
    foreach ($file in @($PatchFile,$SettingsFile,$EconomyScript,$MilestoneScript,$SaleScript)){Assert-File $file}
    Prepare-TunerComponents
    $status=Get-Status $Root
    if ($status.State -notin @('Vanilla','Version010','LocalTest','Managed')) { throw "Installation stopped because the game files are '$($status.State)'. Restore them through Steam before installing." }
    $vanilla=Get-VanillaSources $status
    $backupDirectory = if ($status.State -eq 'Vanilla') { New-VanillaBackup $status.Paths } else { $vanilla.BackupDirectory }
    $operationBackup = New-OperationBackup $status.Paths
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('HardEconomy021-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $baseAssembly=Join-Path $temporary 'base.dll'; $finalAssembly=Join-Path $temporary 'GameAssembly.dll'
    $economyBundle=Join-Path $temporary 'economy.bundle'; $finalBundle=Join-Path $temporary 'final.bundle'
    try {
        Apply-BasePatch $vanilla.Assembly $baseAssembly
        $sale=& $SaleScript -SourceGameAssembly $baseAssembly -OutputGameAssembly $finalAssembly -SettingsFile $SettingsFile
        $economy=& $EconomyScript -InputBundle $vanilla.Bundle -OutputBundle $economyBundle -ToolDirectory $ToolDirectory -GameAssembly $vanilla.Assembly -GlobalMetadata $status.Paths.Metadata -SettingsFile $SettingsFile
        $milestones=& $MilestoneScript -InputBundle $economyBundle -OutputBundle $finalBundle -ToolDirectory $ToolDirectory -GameAssembly $vanilla.Assembly -GlobalMetadata $status.Paths.Metadata
        $assemblyHash=Get-Sha256 $finalAssembly; $bundleHash=Get-Sha256 $finalBundle
        if ($assemblyHash -ne $sale.OutputSha256 -or $bundleHash -ne $milestones.OutputSha256) { throw 'Generated files failed final validation.' }
        Copy-Item $finalAssembly $status.Paths.Assembly -Force; Copy-Item $finalBundle $status.Paths.Bundle -Force
        if ((Get-Sha256 $status.Paths.Assembly) -ne $assemblyHash -or (Get-Sha256 $status.Paths.Bundle) -ne $bundleHash) { throw 'Installed files failed validation.' }
        New-Item -ItemType Directory -Path $status.Paths.BackupRoot -Force | Out-Null
        Copy-Item $SettingsFile (Join-Path $status.Paths.BackupRoot 'HardEconomy-LastAppliedSettings.txt') -Force
        [pscustomobject]@{modVersion=$ModVersion;installedAt=(Get-Date).ToString('o');gameDirectory=$status.Paths.Root;backupDirectory=$backupDirectory;settingsSha256=(Get-Sha256 $SettingsFile);vanillaAssemblySha256=$VanillaAssemblySha256;vanillaBundleSha256=$VanillaBundleSha256;hardModeAssemblySha256=$assemblyHash;hardModeBundleSha256=$bundleHash} | ConvertTo-Json | Set-Content $status.Paths.State -Encoding UTF8
        return "Hard Economy $ModVersion was applied successfully.`r`nSettings: $SettingsFile`r`nOriginal backup: $backupDirectory"
    } catch {
        try {
            Restore-OperationFiles $status.Paths $operationBackup $status.AssemblySha256 $status.BundleSha256
        } catch {
            throw "Installation failed and automatic rollback also failed. Recovery copy: $operationBackup; original backup: $backupDirectory"
        }
        throw
    } finally { Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue }
}

function Restore-HardEconomy {
    param([string]$Root)
    Assert-GameClosed
    $status=Get-Status $Root
    if ($status.State -eq 'Vanilla') { return 'The supported original Steam files are already active.' }
    if ($status.State -notin @('Version010','LocalTest','Managed')) { throw "Restoration stopped because the game files are '$($status.State)'. Use Steam file verification instead." }
    $vanilla=Get-VanillaSources $status
    Restore-VanillaFiles $status.Paths $vanilla.BackupDirectory
    return "Original Construction Simulator files restored successfully.`r`nBackup kept at: $($vanilla.BackupDirectory)"
}

function Format-Status { param($Status) switch($Status.State){'Vanilla'{"Supported original Steam files detected. Hard Economy $ModVersion can be applied."}'Version010'{"Hard Economy 0.1.0-beta detected. It can be updated to $ModVersion."}'LocalTest'{"The known Hard Economy local test build is active. It can be updated to $ModVersion."}'Managed'{"Managed Hard Economy $($Status.SavedState.modVersion) is active. Apply to rebuild it as $ModVersion."}'Mixed'{'Mixed game files detected. No changes will be made.'}default{'Unsupported or externally modified game files detected. No changes will be made.'}} }

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=[Windows.Forms.Form]::new();$form.Text="Construction Simulator - Hard Economy $ModVersion";$form.StartPosition='CenterScreen';$form.ClientSize=[Drawing.Size]::new(720,455);$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
    $title=[Windows.Forms.Label]::new();$title.Text='Hard Economy';$title.Font=[Drawing.Font]::new('Segoe UI',18,[Drawing.FontStyle]::Bold);$title.Location=[Drawing.Point]::new(24,18);$title.AutoSize=$true;$form.Controls.Add($title)
    $subtitle=[Windows.Forms.Label]::new();$subtitle.Text="Version $ModVersion - configurable economy patcher";$subtitle.Location=[Drawing.Point]::new(28,58);$subtitle.Size=[Drawing.Size]::new(660,23);$form.Controls.Add($subtitle)
    $pathLabel=[Windows.Forms.Label]::new();$pathLabel.Text='Construction Simulator folder:';$pathLabel.Location=[Drawing.Point]::new(28,92);$pathLabel.AutoSize=$true;$form.Controls.Add($pathLabel)
    $path=[Windows.Forms.TextBox]::new();$path.Location=[Drawing.Point]::new(28,116);$path.Size=[Drawing.Size]::new(550,24);$path.Text=if([string]::IsNullOrWhiteSpace($GameDirectory)){Find-DefaultGameRoot}else{$GameDirectory};$form.Controls.Add($path)
    $browse=[Windows.Forms.Button]::new();$browse.Text='Browse...';$browse.Location=[Drawing.Point]::new(590,114);$browse.Size=[Drawing.Size]::new(100,28);$form.Controls.Add($browse)
    $output=[Windows.Forms.TextBox]::new();$output.Location=[Drawing.Point]::new(28,158);$output.Size=[Drawing.Size]::new(662,170);$output.Multiline=$true;$output.ReadOnly=$true;$output.ScrollBars='Vertical';$output.Text="Edit HardEconomy-Settings.txt if desired, then click Apply.`r`nThe game must be closed.";$form.Controls.Add($output)
    $statusButton=[Windows.Forms.Button]::new();$statusButton.Text='Check status';$statusButton.Location=[Drawing.Point]::new(28,355);$statusButton.Size=[Drawing.Size]::new(125,38);$form.Controls.Add($statusButton)
    $apply=[Windows.Forms.Button]::new();$apply.Text='Apply Hard Economy';$apply.Location=[Drawing.Point]::new(165,355);$apply.Size=[Drawing.Size]::new(150,38);$form.Controls.Add($apply)
    $restore=[Windows.Forms.Button]::new();$restore.Text='Restore originals';$restore.Location=[Drawing.Point]::new(327,355);$restore.Size=[Drawing.Size]::new(145,38);$form.Controls.Add($restore)
    $close=[Windows.Forms.Button]::new();$close.Text='Close';$close.Location=[Drawing.Point]::new(565,355);$close.Size=[Drawing.Size]::new(125,38);$form.Controls.Add($close)
    $run={param([scriptblock]$Operation)$form.UseWaitCursor=$true;$statusButton.Enabled=$false;$apply.Enabled=$false;$restore.Enabled=$false;[Windows.Forms.Application]::DoEvents();try{$output.Text=&$Operation}catch{$output.Text="Stopped safely:`r`n$($_.Exception.Message)";[Windows.Forms.MessageBox]::Show($output.Text,'Hard Economy',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null}finally{$form.UseWaitCursor=$false;$statusButton.Enabled=$true;$apply.Enabled=$true;$restore.Enabled=$true}}
    $browse.Add_Click({$dialog=[Windows.Forms.FolderBrowserDialog]::new();$dialog.Description='Select the folder containing ConSim.exe.';if(Test-Path $path.Text){$dialog.SelectedPath=$path.Text};if($dialog.ShowDialog()-eq[Windows.Forms.DialogResult]::OK){$path.Text=$dialog.SelectedPath};$dialog.Dispose()})
    $statusButton.Add_Click({&$run{Format-Status (Get-Status $path.Text)}})
    $apply.Add_Click({if([Windows.Forms.MessageBox]::Show('Apply Hard Economy using HardEconomy-Settings.txt? A validated original-file backup is required and retained.','Apply Hard Economy',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)-eq[Windows.Forms.DialogResult]::Yes){&$run{Install-HardEconomy $path.Text}}})
    $restore.Add_Click({if([Windows.Forms.MessageBox]::Show('Restore the supported original Construction Simulator files?','Restore originals',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)-eq[Windows.Forms.DialogResult]::Yes){&$run{Restore-HardEconomy $path.Text}}})
    $close.Add_Click({$form.Close()});[void]$form.ShowDialog();$form.Dispose()
}

if($Action-eq'Gui'){Show-Gui}else{if([string]::IsNullOrWhiteSpace($GameDirectory)){$GameDirectory=Find-DefaultGameRoot};if([string]::IsNullOrWhiteSpace($GameDirectory)){throw 'No Construction Simulator folder was supplied or detected.'};switch($Action){'Install'{Install-HardEconomy $GameDirectory}'Restore'{Restore-HardEconomy $GameDirectory}'Status'{Format-Status (Get-Status $GameDirectory)}}}
