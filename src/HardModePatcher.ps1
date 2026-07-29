param(
    [ValidateSet('Gui', 'Install', 'Restore', 'Status')]
    [string]$Action = 'Gui',

    [string]$GameDirectory
)

$ErrorActionPreference = 'Stop'

$ModVersion = '0.1.0-beta'
$VanillaAssemblySha256 = '404C1A5077AB26C7B8456D6F8A686DB73CCDBC424A550D21F62F1E241CEAEB91'
$HardModeAssemblySha256 = '93CD70E11A6E3FE30EF5863600467753EC9A53CA2D7955881FDC7A003C13C1CF'
$VanillaBundleSha256 = '1183BF9CC81DA0341CAE865BAF17B1310F7C9992B46C8C1DD46848AF1FA6839C'
$HardModeBundleSha256 = '648886D676450869BDFDE02F33A000804B42C8B7BE80556B765C548D4E9039EF'
$BundleRelativePath = 'ConSim_Data\StreamingAssets\aa\9c26e1001ca50c672968ec008c8995f1.bundle'
$MetadataRelativePath = 'ConSim_Data\il2cpp_data\Metadata\global-metadata.dat'
$PatchFile = Join-Path $PSScriptRoot 'payload\GameAssembly.hmpatch'
$EconomyPatchScript = Join-Path $PSScriptRoot 'Apply-HardModeEconomyBundle.ps1'
$ToolDirectory = Join-Path $PSScriptRoot 'tools'

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-GameRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return Test-Path -LiteralPath (Join-Path $Path 'ConSim.exe') -PathType Leaf
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
            $installLocation = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop).InstallLocation
            if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                $candidates.Add($installLocation)
            }
        }
        catch {
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-GameRoot $candidate) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return ''
}

function Get-RequiredPaths {
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    if (-not (Test-GameRoot $resolvedRoot)) {
        throw "The selected folder does not contain ConSim.exe."
    }

    $paths = [ordered]@{
        Root = $resolvedRoot
        Assembly = Join-Path $resolvedRoot 'GameAssembly.dll'
        Bundle = Join-Path $resolvedRoot $BundleRelativePath
        Metadata = Join-Path $resolvedRoot $MetadataRelativePath
        BackupRoot = Join-Path $resolvedRoot 'HardMode_Backups'
        State = Join-Path $resolvedRoot 'HardMode_Backups\install-state.json'
    }
    foreach ($requiredFile in @($paths.Assembly, $paths.Bundle, $paths.Metadata)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required Construction Simulator file is missing: $requiredFile"
        }
    }
    return [pscustomobject]$paths
}

function Get-InstallationStatus {
    param([Parameter(Mandatory = $true)][string]$Root)

    $paths = Get-RequiredPaths $Root
    $assemblyHash = Get-Sha256 $paths.Assembly
    $bundleHash = Get-Sha256 $paths.Bundle

    $state = if ($assemblyHash -eq $VanillaAssemblySha256 -and $bundleHash -eq $VanillaBundleSha256) {
        'Vanilla'
    }
    elseif ($assemblyHash -eq $HardModeAssemblySha256 -and $bundleHash -eq $HardModeBundleSha256) {
        'HardMode'
    }
    elseif (
        $assemblyHash -in @($VanillaAssemblySha256, $HardModeAssemblySha256) -or
        $bundleHash -in @($VanillaBundleSha256, $HardModeBundleSha256)
    ) {
        'Mixed'
    }
    else {
        'Unsupported'
    }

    return [pscustomobject]@{
        State = $state
        AssemblySha256 = $assemblyHash
        BundleSha256 = $bundleHash
        Paths = $paths
    }
}

function Convert-HexToBytes {
    param([Parameter(Mandatory = $true)][string]$Hex)
    $bytes = [byte[]]::new($Hex.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return $bytes
}

function Convert-BytesToHex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ([BitConverter]::ToString($Bytes)).Replace('-', '')
}

function Apply-GameAssemblyPatch {
    param(
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$OutputFile
    )

    if (-not (Test-Path -LiteralPath $PatchFile -PathType Leaf)) {
        throw "GameAssembly patch payload is missing: $PatchFile"
    }

    $inputHash = Get-Sha256 $InputFile
    if ($inputHash -ne $VanillaAssemblySha256) {
        throw "GameAssembly.dll is not the supported original Steam version."
    }

    Copy-Item -LiteralPath $InputFile -Destination $OutputFile -Force
    $patchStream = [System.IO.File]::OpenRead($PatchFile)
    $reader = [System.IO.BinaryReader]::new($patchStream)
    try {
        $magic = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne 'HMP1') {
            throw 'The GameAssembly patch payload has an invalid header.'
        }

        $expectedLength = $reader.ReadInt64()
        $sourceHash = Convert-BytesToHex ($reader.ReadBytes(32))
        $targetHash = Convert-BytesToHex ($reader.ReadBytes(32))
        $rangeCount = $reader.ReadInt32()
        $outputInfo = Get-Item -LiteralPath $OutputFile

        if ($outputInfo.Length -ne $expectedLength) {
            throw 'GameAssembly.dll has an unsupported file length.'
        }
        if ($sourceHash -ne $VanillaAssemblySha256 -or $targetHash -ne $HardModeAssemblySha256) {
            throw 'The GameAssembly patch payload does not belong to this Hard Economy version.'
        }
        if ($rangeCount -lt 1 -or $rangeCount -gt 10000) {
            throw 'The GameAssembly patch payload contains an invalid range count.'
        }

        $outputStream = [System.IO.File]::Open(
            $OutputFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            for ($rangeIndex = 0; $rangeIndex -lt $rangeCount; $rangeIndex++) {
                $offset = $reader.ReadInt64()
                $length = $reader.ReadInt32()
                if ($offset -lt 0 -or $length -lt 1 -or ($offset + $length) -gt $expectedLength) {
                    throw 'The GameAssembly patch payload contains an invalid byte range.'
                }
                $replacement = $reader.ReadBytes($length)
                if ($replacement.Length -ne $length) {
                    throw 'The GameAssembly patch payload ended unexpectedly.'
                }
                $outputStream.Position = $offset
                $outputStream.Write($replacement, 0, $replacement.Length)
            }
            $outputStream.Flush()
        }
        finally {
            $outputStream.Dispose()
        }
    }
    finally {
        $reader.Dispose()
        $patchStream.Dispose()
    }

    $outputHash = Get-Sha256 $OutputFile
    if ($outputHash -ne $HardModeAssemblySha256) {
        throw "Generated GameAssembly.dll failed validation. Found $outputHash."
    }
}

function New-HardModeBackup {
    param([Parameter(Mandatory = $true)]$Paths)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDirectory = Join-Path $Paths.BackupRoot "$stamp-before-$ModVersion"
    $backupBundleDirectory = Join-Path $backupDirectory (Split-Path -Parent $BundleRelativePath)
    New-Item -ItemType Directory -Path $backupBundleDirectory -Force | Out-Null
    Copy-Item -LiteralPath $Paths.Assembly -Destination (Join-Path $backupDirectory 'GameAssembly.dll')
    Copy-Item -LiteralPath $Paths.Bundle -Destination (Join-Path $backupDirectory $BundleRelativePath)

    $backupAssemblyHash = Get-Sha256 (Join-Path $backupDirectory 'GameAssembly.dll')
    $backupBundleHash = Get-Sha256 (Join-Path $backupDirectory $BundleRelativePath)
    if ($backupAssemblyHash -ne $VanillaAssemblySha256 -or $backupBundleHash -ne $VanillaBundleSha256) {
        throw 'The automatic backup did not match the supported original files.'
    }
    return $backupDirectory
}

function Restore-FromBackupDirectory {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$BackupDirectory
    )

    $backupAssembly = Join-Path $BackupDirectory 'GameAssembly.dll'
    $backupBundle = Join-Path $BackupDirectory $BundleRelativePath
    if (-not (Test-Path -LiteralPath $backupAssembly) -or -not (Test-Path -LiteralPath $backupBundle)) {
        throw 'The recorded Hard Economy backup is incomplete.'
    }
    if ((Get-Sha256 $backupAssembly) -ne $VanillaAssemblySha256) {
        throw 'The backup of GameAssembly.dll is not the supported original.'
    }
    if ((Get-Sha256 $backupBundle) -ne $VanillaBundleSha256) {
        throw 'The backup of the economy bundle is not the supported original.'
    }

    Copy-Item -LiteralPath $backupAssembly -Destination $Paths.Assembly -Force
    Copy-Item -LiteralPath $backupBundle -Destination $Paths.Bundle -Force
    if ((Get-Sha256 $Paths.Assembly) -ne $VanillaAssemblySha256 -or
        (Get-Sha256 $Paths.Bundle) -ne $VanillaBundleSha256) {
        throw 'Restored files failed validation.'
    }
}

function Install-HardMode {
    param([Parameter(Mandatory = $true)][string]$Root)

    $status = Get-InstallationStatus $Root
    if ($status.State -eq 'HardMode') {
        return 'Hard Economy is already installed and both files are valid.'
    }
    if ($status.State -ne 'Vanilla') {
        throw "Installation stopped because the game files are '$($status.State)'. Restore them through Steam before installing Hard Economy."
    }
    foreach ($patcherFile in @(
        $PatchFile,
        $EconomyPatchScript,
        (Join-Path $ToolDirectory 'AssetsTools.NET.dll'),
        (Join-Path $ToolDirectory 'AssetsTools.NET.Cpp2IL.dll'),
        (Join-Path $ToolDirectory 'classdata.tpk')
    )) {
        if (-not (Test-Path -LiteralPath $patcherFile -PathType Leaf)) {
            throw "Patcher component is missing: $patcherFile"
        }
    }

    $backupDirectory = New-HardModeBackup $status.Paths
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('HardModePatcher-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    $temporaryAssembly = Join-Path $temporaryDirectory 'GameAssembly.dll'
    $temporaryBundle = Join-Path $temporaryDirectory 'economy.bundle'

    try {
        Apply-GameAssemblyPatch -InputFile $status.Paths.Assembly -OutputFile $temporaryAssembly
        & $EconomyPatchScript `
            -InputBundle $status.Paths.Bundle `
            -OutputBundle $temporaryBundle `
            -ToolDirectory $ToolDirectory `
            -GameAssembly $status.Paths.Assembly `
            -GlobalMetadata $status.Paths.Metadata | Out-Null

        if ((Get-Sha256 $temporaryAssembly) -ne $HardModeAssemblySha256 -or
            (Get-Sha256 $temporaryBundle) -ne $HardModeBundleSha256) {
            throw 'Generated Hard Economy files failed final validation.'
        }

        Copy-Item -LiteralPath $temporaryAssembly -Destination $status.Paths.Assembly -Force
        Copy-Item -LiteralPath $temporaryBundle -Destination $status.Paths.Bundle -Force

        $installedStatus = Get-InstallationStatus $Root
        if ($installedStatus.State -ne 'HardMode') {
            throw 'Installed files failed validation.'
        }

        New-Item -ItemType Directory -Path $status.Paths.BackupRoot -Force | Out-Null
        [pscustomobject]@{
            modVersion = $ModVersion
            installedAt = (Get-Date).ToString('o')
            gameDirectory = $status.Paths.Root
            backupDirectory = $backupDirectory
            vanillaAssemblySha256 = $VanillaAssemblySha256
            vanillaBundleSha256 = $VanillaBundleSha256
            hardModeAssemblySha256 = $HardModeAssemblySha256
            hardModeBundleSha256 = $HardModeBundleSha256
        } | ConvertTo-Json | Set-Content -LiteralPath $status.Paths.State -Encoding UTF8

        return "Hard Economy $ModVersion was installed successfully.`r`nBackup: $backupDirectory"
    }
    catch {
        try {
            Restore-FromBackupDirectory -Paths $status.Paths -BackupDirectory $backupDirectory
        }
        catch {
            throw "Installation failed and automatic restoration also failed. Original backup: $backupDirectory"
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}

function Restore-HardMode {
    param([Parameter(Mandatory = $true)][string]$Root)

    $status = Get-InstallationStatus $Root
    if ($status.State -eq 'Vanilla') {
        return 'The original Construction Simulator files are already active.'
    }
    if ($status.State -ne 'HardMode') {
        throw "Restoration stopped because the game files are '$($status.State)'. Use Steam's file verification instead."
    }
    if (-not (Test-Path -LiteralPath $status.Paths.State -PathType Leaf)) {
        throw "No Hard Economy backup record was found. Use Steam's file verification to restore the game."
    }

    $savedState = Get-Content -LiteralPath $status.Paths.State -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($savedState.backupDirectory)) {
        throw 'The Hard Economy backup record is invalid.'
    }
    Restore-FromBackupDirectory -Paths $status.Paths -BackupDirectory $savedState.backupDirectory

    $savedState | Add-Member -NotePropertyName restoredAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $savedState | ConvertTo-Json | Set-Content -LiteralPath $status.Paths.State -Encoding UTF8
    return "The original Construction Simulator files were restored successfully.`r`nBackup kept at: $($savedState.backupDirectory)"
}

function Format-StatusText {
    param([Parameter(Mandatory = $true)]$Status)
    switch ($Status.State) {
        'Vanilla' { return 'Supported original Steam files detected. Hard Economy can be installed.' }
        'HardMode' { return "Hard Economy $ModVersion is installed and both files are valid." }
        'Mixed' { return 'The two files are from different versions. Installation is blocked for safety.' }
        default { return 'Unknown or updated game files detected. Installation is blocked for safety.' }
    }
}

function Show-PatcherGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "Construction Simulator - Hard Economy Patcher $ModVersion"
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = [Drawing.Size]::new(700, 430)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $title = [System.Windows.Forms.Label]::new()
    $title.Text = 'Hard Economy'
    $title.Font = [Drawing.Font]::new('Segoe UI', 18, [Drawing.FontStyle]::Bold)
    $title.Location = [Drawing.Point]::new(24, 20)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $subtitle = [System.Windows.Forms.Label]::new()
    $subtitle.Text = 'Safe local installer - no original game files are included'
    $subtitle.Location = [Drawing.Point]::new(28, 60)
    $subtitle.Size = [Drawing.Size]::new(640, 24)
    $form.Controls.Add($subtitle)

    $pathLabel = [System.Windows.Forms.Label]::new()
    $pathLabel.Text = 'Construction Simulator folder:'
    $pathLabel.Location = [Drawing.Point]::new(28, 98)
    $pathLabel.AutoSize = $true
    $form.Controls.Add($pathLabel)

    $pathBox = [System.Windows.Forms.TextBox]::new()
    $pathBox.Location = [Drawing.Point]::new(28, 122)
    $pathBox.Size = [Drawing.Size]::new(540, 24)
    $pathBox.Text = if ([string]::IsNullOrWhiteSpace($GameDirectory)) { Find-DefaultGameRoot } else { $GameDirectory }
    $form.Controls.Add($pathBox)

    $browseButton = [System.Windows.Forms.Button]::new()
    $browseButton.Text = 'Browse...'
    $browseButton.Location = [Drawing.Point]::new(580, 120)
    $browseButton.Size = [Drawing.Size]::new(90, 28)
    $form.Controls.Add($browseButton)

    $outputBox = [System.Windows.Forms.TextBox]::new()
    $outputBox.Location = [Drawing.Point]::new(28, 165)
    $outputBox.Size = [Drawing.Size]::new(642, 150)
    $outputBox.Multiline = $true
    $outputBox.ReadOnly = $true
    $outputBox.ScrollBars = 'Vertical'
    $outputBox.Text = 'Select the game folder and click Check status.'
    $form.Controls.Add($outputBox)

    $statusButton = [System.Windows.Forms.Button]::new()
    $statusButton.Text = 'Check status'
    $statusButton.Location = [Drawing.Point]::new(28, 340)
    $statusButton.Size = [Drawing.Size]::new(125, 38)
    $form.Controls.Add($statusButton)

    $installButton = [System.Windows.Forms.Button]::new()
    $installButton.Text = 'Install Hard Economy'
    $installButton.Location = [Drawing.Point]::new(165, 340)
    $installButton.Size = [Drawing.Size]::new(145, 38)
    $form.Controls.Add($installButton)

    $restoreButton = [System.Windows.Forms.Button]::new()
    $restoreButton.Text = 'Restore originals'
    $restoreButton.Location = [Drawing.Point]::new(322, 340)
    $restoreButton.Size = [Drawing.Size]::new(145, 38)
    $form.Controls.Add($restoreButton)

    $closeButton = [System.Windows.Forms.Button]::new()
    $closeButton.Text = 'Close'
    $closeButton.Location = [Drawing.Point]::new(545, 340)
    $closeButton.Size = [Drawing.Size]::new(125, 38)
    $form.Controls.Add($closeButton)

    $runOperation = {
        param([scriptblock]$Operation)
        $form.UseWaitCursor = $true
        $statusButton.Enabled = $false
        $installButton.Enabled = $false
        $restoreButton.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $outputBox.Text = (& $Operation)
        }
        catch {
            $outputBox.Text = "Stopped safely:`r`n$($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                $outputBox.Text,
                'Hard Economy Patcher',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
        finally {
            $form.UseWaitCursor = $false
            $statusButton.Enabled = $true
            $installButton.Enabled = $true
            $restoreButton.Enabled = $true
        }
    }

    $browseButton.Add_Click({
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = 'Select the Construction Simulator folder containing ConSim.exe.'
        if (Test-Path -LiteralPath $pathBox.Text -PathType Container) {
            $dialog.SelectedPath = $pathBox.Text
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $pathBox.Text = $dialog.SelectedPath
        }
        $dialog.Dispose()
    })

    $statusButton.Add_Click({
        & $runOperation {
            $status = Get-InstallationStatus $pathBox.Text
            Format-StatusText $status
        }
    })

    $installButton.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'Install Hard Economy? The patcher will create and validate a complete backup first.',
            'Install Hard Economy',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            & $runOperation { Install-HardMode $pathBox.Text }
        }
    })

    $restoreButton.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'Restore the original Construction Simulator files from the automatic backup?',
            'Restore original files',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            & $runOperation { Restore-HardMode $pathBox.Text }
        }
    })

    $closeButton.Add_Click({ $form.Close() })
    [void]$form.ShowDialog()
    $form.Dispose()
}

if ($Action -eq 'Gui') {
    Show-PatcherGui
}
else {
    if ([string]::IsNullOrWhiteSpace($GameDirectory)) {
        $GameDirectory = Find-DefaultGameRoot
    }
    if ([string]::IsNullOrWhiteSpace($GameDirectory)) {
        throw 'No Construction Simulator folder was supplied or detected.'
    }

    switch ($Action) {
        'Install' { Install-HardMode $GameDirectory }
        'Restore' { Restore-HardMode $GameDirectory }
        'Status' { Format-StatusText (Get-InstallationStatus $GameDirectory) }
    }
}
