param(
    [Parameter(Mandatory = $true)]
    [string]$InputBundle,

    [Parameter(Mandatory = $true)]
    [string]$OutputBundle,

    [Parameter(Mandatory = $true)]
    [string]$ToolDirectory,

    [Parameter(Mandatory = $true)]
    [string]$GameAssembly,

    [Parameter(Mandatory = $true)]
    [string]$GlobalMetadata
)

$ErrorActionPreference = 'Stop'

$ExpectedVanillaBundleSha256 = '1183BF9CC81DA0341CAE865BAF17B1310F7C9992B46C8C1DD46848AF1FA6839C'
$ExpectedHardModeBundleSha256 = '648886D676450869BDFDE02F33A000804B42C8B7BE80556B765C548D4E9039EF'

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw "$Label is '$Actual'; expected '$Expected'. The installed game file is not the supported Steam version."
    }
}

function Assert-Float {
    param([double]$Actual, [double]$Expected, [string]$Label)
    if ([math]::Abs($Actual - $Expected) -gt 0.000001) {
        throw "$Label is '$Actual'; expected '$Expected'. The installed game file is not the supported Steam version."
    }
}

function Write-ModifiedAssetsFile {
    param(
        [Parameter(Mandatory = $true)]$AssetsFileInstance,
        [Parameter(Mandatory = $true)][array]$AssetInfos,
        [Parameter(Mandatory = $true)][array]$BaseFields,
        [Parameter(Mandatory = $true)]$ClassDatabase
    )

    Assert-Equal $AssetInfos.Count $BaseFields.Count 'Number of asset replacements'
    $replacements = [System.Collections.Generic.List[AssetsTools.NET.AssetsReplacer]]::new()
    $createdReplacements = [System.Collections.Generic.List[System.IDisposable]]::new()
    try {
        for ($index = 0; $index -lt $AssetInfos.Count; $index++) {
            $replacement = [AssetsTools.NET.AssetsReplacerFromMemory]::new(
                $AssetsFileInstance.file,
                $AssetInfos[$index],
                $BaseFields[$index]
            )
            $replacements.Add($replacement)
            $createdReplacements.Add($replacement)
        }

        $stream = [System.IO.MemoryStream]::new()
        $writer = [AssetsTools.NET.AssetsFileWriter]::new($stream)
        try {
            $AssetsFileInstance.file.Write($writer, 0, $replacements, $ClassDatabase)
            $writer.Flush()
            return $stream.ToArray()
        }
        finally {
            $writer.Dispose()
            $stream.Dispose()
        }
    }
    finally {
        foreach ($replacement in $createdReplacements) {
            $replacement.Dispose()
        }
    }
}

$assetsToolsPath = Join-Path $ToolDirectory 'AssetsTools.NET.dll'
$cpp2IlPath = Join-Path $ToolDirectory 'AssetsTools.NET.Cpp2IL.dll'
$classPackagePath = Join-Path $ToolDirectory 'classdata.tpk'
foreach ($requiredTool in @($assetsToolsPath, $cpp2IlPath, $classPackagePath)) {
    if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
        throw "Required patcher component is missing: $requiredTool"
    }
}

Add-Type -Path $assetsToolsPath
Add-Type -Path $cpp2IlPath

$inputPath = (Resolve-Path -LiteralPath $InputBundle).Path
$assemblyPath = (Resolve-Path -LiteralPath $GameAssembly).Path
$metadataPath = (Resolve-Path -LiteralPath $GlobalMetadata).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputBundle)
$uncompressedPath = "$outputPath.uncompressed"

$actualInputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $inputPath).Hash
Assert-Equal $actualInputHash $ExpectedVanillaBundleSha256 'Economy bundle SHA-256'

$manager = [AssetsTools.NET.Extra.AssetsManager]::new()
$manager.LoadClassPackage($classPackagePath) | Out-Null
$generator = [AssetsTools.NET.Cpp2IL.Cpp2IlTempGenerator]::new($metadataPath, $assemblyPath)
$manager.MonoTempGenerator = $generator

try {
    $bundle = $manager.LoadBundleFile($inputPath, $true)
    $machineAssets = $manager.LoadAssetsFileFromBundle($bundle, 0, $true)
    $economyAssets = $manager.LoadAssetsFileFromBundle($bundle, 2, $true)
    $classDatabase = $manager.LoadClassDatabaseFromPackage($machineAssets.file.Metadata.UnityVersion)

    $machineInfo = $machineAssets.file.GetAssetInfo(39813)
    $machineBase = $manager.GetBaseField(
        $machineAssets,
        $machineInfo,
        [AssetsTools.NET.Extra.AssetReadFlags]::None
    )
    $machines = $machineBase['machineData']['Array'].Children
    Assert-Equal $machines.Count 140 'Number of machine definitions'

    $rentCount = 0
    $maintenanceCount = 0
    $fuelCount = 0
    $deliveryCount = 0
    foreach ($machine in $machines) {
        $rent = $machine['rentCost'].AsInt
        $maintenance = $machine['maintenanceCost'].AsInt
        $fuel = $machine['fuelCost'].AsInt
        $delivery = $machine['deliveryCost'].AsInt

        if ($rent -ne 0) {
            $machine['rentCost'].AsInt = [int]([long]$rent * 10)
            $rentCount++
        }
        if ($maintenance -ne 0) {
            $machine['maintenanceCost'].AsInt = [int]([long]$maintenance * 4)
            $maintenanceCount++
        }
        if ($fuel -ne 0) {
            $machine['fuelCost'].AsInt = [int]([long]$fuel * 4)
            $fuelCount++
        }
        if ($delivery -ne 0) {
            $machine['deliveryCost'].AsInt = [int]([long]$delivery * 10)
            $deliveryCount++
        }
    }

    Assert-Equal $rentCount 138 'Machines with rental prices'
    Assert-Equal $maintenanceCount 139 'Machines with maintenance prices'
    Assert-Equal $fuelCount 138 'Machines with fuel prices'
    Assert-Equal $deliveryCount 130 'Machines with transport prices'

    $economyInfo = $economyAssets.file.GetAssetInfo(561)
    $economyBase = $manager.GetBaseField(
        $economyAssets,
        $economyInfo,
        [AssetsTools.NET.Extra.AssetReadFlags]::None
    )

    Assert-Equal $economyBase['soilPrize'].AsInt 600 'Soil price'
    Assert-Equal $economyBase['gravelPrize'].AsInt 1000 'Gravel price'
    Assert-Equal $economyBase['sandPrize'].AsInt 750 'Sand price'
    Assert-Equal $economyBase['concretePrize'].AsInt 500 'Concrete price'
    Assert-Equal $economyBase['asphaltPrize'].AsInt 1500 'Asphalt price'
    Assert-Float $economyBase['bulkPriceMultiplierHelper'].AsFloat 1.25 'Instant bulk fill multiplier'
    Assert-Float $economyBase['cargoTransportCostMultiplierWarehouse'].AsFloat 0.10 'Warehouse delivery multiplier'
    Assert-Float $economyBase['cargoTransportCostMultiplierMissionSite'].AsFloat 0.15 'Mission-site delivery multiplier'
    Assert-Equal $economyBase['craneSetupCost'].AsInt 5000 'Crane setup cost'
    Assert-Float $economyBase['craneTransportCostPerKm'].AsFloat 0.003 'Crane transport multiplier'
    Assert-Float $economyBase['characterFastTravelPricePerMeter'].AsFloat 0.05 'Fast-travel price per meter'
    Assert-Float $economyBase['minFastTravelCostDistance'].AsFloat 250 'Free fast-travel radius'
    Assert-Float $economyBase['sellPriceMultiplierMachines'].AsFloat 0.75 'Machine resale multiplier'
    Assert-Float $economyBase['sellPriceMultiplierCargos'].AsFloat 0.75 'Cargo resale multiplier'
    Assert-Float $economyBase['sellPriceMultiplierBulk'].AsFloat 0.75 'Bulk resale multiplier'
    Assert-Float $economyBase['sellPriceMultiplierBulkHelper'].AsFloat 0.50 'Instant empty payout multiplier'
    Assert-Float $economyBase['loanRate'].AsFloat 0.02 'Loan rate'

    $economyBase['soilPrize'].AsInt = 1200
    $economyBase['gravelPrize'].AsInt = 2000
    $economyBase['sandPrize'].AsInt = 1500
    $economyBase['concretePrize'].AsInt = 1000
    $economyBase['asphaltPrize'].AsInt = 3000
    $economyBase['bulkPriceMultiplierHelper'].AsFloat = 3.0
    $economyBase['cargoTransportCostMultiplierWarehouse'].AsFloat = 0.50
    $economyBase['cargoTransportCostMultiplierMissionSite'].AsFloat = 0.75
    $economyBase['craneSetupCost'].AsInt = 25000
    $economyBase['craneTransportCostPerKm'].AsFloat = 0.015
    $economyBase['characterFastTravelPricePerMeter'].AsFloat = 0.50
    $economyBase['sellPriceMultiplierMachines'].AsFloat = 0.50
    $economyBase['sellPriceMultiplierCargos'].AsFloat = 0.375
    $economyBase['sellPriceMultiplierBulk'].AsFloat = 0.09375
    $economyBase['sellPriceMultiplierBulkHelper'].AsFloat = 0.0

    $cargoInfo = $economyAssets.file.GetAssetInfo(602)
    $cargoBase = $manager.GetBaseField(
        $economyAssets,
        $cargoInfo,
        [AssetsTools.NET.Extra.AssetReadFlags]::None
    )
    $cargoData = $cargoBase['cargoData']['Array'].Children
    Assert-Equal $cargoData.Count 1037 'Number of cargo definitions'

    $purchasableCount = 0
    $nonPurchasableCount = 0
    foreach ($cargo in $cargoData) {
        if ($cargo['cargoIsPurchasable'].AsBool) {
            $oldPrice = $cargo['price'].AsInt
            if ($oldPrice -le 0) {
                throw "Purchasable cargo $($cargo['cargoID'].AsInt) has an invalid price of $oldPrice."
            }
            $cargo['price'].AsInt = [int]([long]$oldPrice * 2)
            $purchasableCount++
        }
        else {
            $nonPurchasableCount++
        }
    }
    Assert-Equal $purchasableCount 66 'Purchasable construction materials'
    Assert-Equal $nonPurchasableCount 971 'Non-purchasable mission objects'

    $machineInfos = [object[]]::new(1)
    $machineFields = [object[]]::new(1)
    $machineInfos[0] = $machineInfo
    $machineFields[0] = $machineBase
    $machineBytes = Write-ModifiedAssetsFile `
        -AssetsFileInstance $machineAssets `
        -AssetInfos $machineInfos `
        -BaseFields $machineFields `
        -ClassDatabase $classDatabase

    $economyInfos = [object[]]::new(2)
    $economyFields = [object[]]::new(2)
    $economyInfos[0] = $economyInfo
    $economyInfos[1] = $cargoInfo
    $economyFields[0] = $economyBase
    $economyFields[1] = $cargoBase
    $economyBytes = Write-ModifiedAssetsFile `
        -AssetsFileInstance $economyAssets `
        -AssetInfos $econo…4262 tokens truncated…toration stopped because the game files are '$($status.State)'. Use Steam's file verification instead."
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
