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
    [string]$GlobalMetadata,

    [Parameter(Mandatory = $true)]
    [string]$SettingsFile
)

$ErrorActionPreference = 'Stop'

$ExpectedVanillaBundleSha256 = '1183BF9CC81DA0341CAE865BAF17B1310F7C9992B46C8C1DD46848AF1FA6839C'
$RequiredSettingNames = @(
    'RentalMultiplier',
    'MachinePurchasePriceMultiplier',
    'FuelMultiplier',
    'MaintenanceMultiplier',
    'MachineTransportMultiplier',
    'BulkMaterialPriceMultiplier',
    'BuildingMaterialPriceMultiplier',
    'BuildingMaterialSaleMaxActive',
    'BuildingMaterialSaleHourlyChancePercent',
    'VehicleSaleMaxActive',
    'VehicleSaleHourlyChancePercent',
    'FastTravelMultiplier',
    'MachineResalePercent',
    'InstantFillPriceMultiplier',
    'InstantEmptyPayoutPercent',
    'WarehouseDeliveryCostMultiplier',
    'ConstructionSiteDeliveryCostMultiplier',
    'CraneTransportMultiplier',
    'PhysicalBulkResalePercent',
    'BuildingMaterialResalePercent'
)
$PercentSettingNames = @(
    'MachineResalePercent',
    'InstantEmptyPayoutPercent',
    'PhysicalBulkResalePercent',
    'BuildingMaterialResalePercent',
    'BuildingMaterialSaleHourlyChancePercent',
    'VehicleSaleHourlyChancePercent'
)
$SettingRanges = @{
    RentalMultiplier                         = @(0.0, 20.0)
    MachinePurchasePriceMultiplier            = @(0.0, 20.0)
    FuelMultiplier                            = @(0.0, 20.0)
    MaintenanceMultiplier                     = @(0.0, 20.0)
    MachineTransportMultiplier                = @(0.0, 20.0)
    BulkMaterialPriceMultiplier               = @(0.0, 20.0)
    BuildingMaterialPriceMultiplier           = @(0.0, 20.0)
    BuildingMaterialSaleMaxActive              = @(0.0, 50.0)
    BuildingMaterialSaleHourlyChancePercent    = @(0.0, 50.0)
    VehicleSaleMaxActive                       = @(0.0, 50.0)
    VehicleSaleHourlyChancePercent             = @(0.0, 50.0)
    FastTravelMultiplier                       = @(0.0, 20.0)
    MachineResalePercent                       = @(0.0, 100.0)
    InstantFillPriceMultiplier                 = @(0.0, 20.0)
    InstantEmptyPayoutPercent                  = @(0.0, 20.0)
    WarehouseDeliveryCostMultiplier            = @(0.0, 20.0)
    ConstructionSiteDeliveryCostMultiplier     = @(0.0, 20.0)
    CraneTransportMultiplier                   = @(0.0, 20.0)
    PhysicalBulkResalePercent                  = @(0.0, 100.0)
    BuildingMaterialResalePercent              = @(0.0, 100.0)
}
$WholeNumberSettingNames = @(
    'BuildingMaterialSaleMaxActive',
    'VehicleSaleMaxActive'
)

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw "$Label is '$Actual'; expected '$Expected'. The original game file is not the supported Steam version."
    }
}

function Assert-Float {
    param([double]$Actual, [double]$Expected, [string]$Label)
    if ([math]::Abs($Actual - $Expected) -gt 0.000001) {
        throw "$Label is '$Actual'; expected '$Expected'. The original game file is not the supported Steam version."
    }
}

function Convert-ToGameInt {
    param(
        [Parameter(Mandatory = $true)][int]$VanillaValue,
        [Parameter(Mandatory = $true)][double]$Multiplier,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $calculated = [math]::Round(
        ([double]$VanillaValue * $Multiplier),
        0,
        [MidpointRounding]::AwayFromZero
    )
    if ($calculated -lt 0 -or $calculated -gt [int]::MaxValue) {
        throw "$Label produces a value outside the supported game range."
    }
    return [int]$calculated
}

function Read-TestSettings {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Settings file is missing: $Path"
    }

    $settings = @{}
    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }
        if ($line -notmatch '^([A-Za-z][A-Za-z0-9]*)\s*=\s*(.+)$') {
            throw "Invalid settings line $lineNumber. Use Name=number."
        }

        $name = $matches[1]
        $textValue = ($matches[2] -split '\s+#', 2)[0].Trim()
        if ($name -notin $RequiredSettingNames) {
            throw "Unknown setting '$name' on line $lineNumber."
        }
        if ($settings.ContainsKey($name)) {
            throw "Setting '$name' occurs more than once."
        }
        if ($textValue.Contains(',')) {
            throw "Invalid value for '$name'. Use a decimal point, for example 1.2, not 1,2."
        }

        $number = 0.0
        $parsed = [double]::TryParse(
            $textValue,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        )
        if (-not $parsed -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            throw "Invalid value for '$name'. Use a whole number or a decimal with a dot."
        }
        $minimum = [double]$SettingRanges[$name][0]
        $maximum = [double]$SettingRanges[$name][1]
        if ($number -lt $minimum -or $number -gt $maximum) {
            throw "Setting '$name' must be between $minimum and $maximum."
        }
        if ($name -in $WholeNumberSettingNames -and [math]::Abs($number - [math]::Round($number)) -gt 0.000001) {
            throw "Setting '$name' must be a whole number."
        }

        $settings[$name] = $number
    }

    foreach ($requiredName in $RequiredSettingNames) {
        if (-not $settings.ContainsKey($requiredName)) {
            throw "Required setting '$requiredName' is missing."
        }
    }
    return $settings
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

$settings = Read-TestSettings $SettingsFile
$assetsToolsPath = Join-Path $ToolDirectory 'AssetsTools.NET.dll'
$cpp2IlPath = Join-Path $ToolDirectory 'AssetsTools.NET.Cpp2IL.dll'
$classPackagePath = Join-Path $ToolDirectory 'classdata.tpk'
foreach ($requiredTool in @($assetsToolsPath, $cpp2IlPath, $classPackagePath)) {
    if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
        throw "Required tuner component is missing: $requiredTool"
    }
}

foreach ($assemblyPath in @($assetsToolsPath, $cpp2IlPath)) {
    try { Add-Type -Path $assemblyPath -ErrorAction Stop }
    catch {
        if ($_.Exception.ToString().Contains('0x80131515')) {
            throw "Windows blocked $([IO.Path]::GetFileName($assemblyPath)). Extract the complete Hard Economy ZIP to a local folder and run the patcher again."
        }
        throw
    }
}

$inputPath = (Resolve-Path -LiteralPath $InputBundle).Path
$assemblyPath = (Resolve-Path -LiteralPath $GameAssembly).Path
$metadataPath = (Resolve-Path -LiteralPath $GlobalMetadata).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputBundle)
$uncompressedPath = "$outputPath.uncompressed"

$actualInputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $inputPath).Hash
Assert-Equal $actualInputHash $ExpectedVanillaBundleSha256 'Economy bundle SHA-256'

$manager = [AssetsTools.NET.Extra.AssetsManager]::new()
$generator = $null
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
    $machinePurchasePriceCount = 0
    $maintenanceCount = 0
    $fuelCount = 0
    $deliveryCount = 0
    foreach ($machine in $machines) {
        $purchasePrice = $machine['price'].AsInt
        $rent = $machine['rentCost'].AsInt
        $maintenance = $machine['maintenanceCost'].AsInt
        $fuel = $machine['fuelCost'].AsInt
        $delivery = $machine['deliveryCost'].AsInt

        if ($purchasePrice -ne 0) {
            $machine['price'].AsInt = Convert-ToGameInt `
                $purchasePrice `
                $settings.MachinePurchasePriceMultiplier `
                'MachinePurchasePriceMultiplier'
            $machinePurchasePriceCount++
        }
        if ($rent -ne 0) {
            $machine['rentCost'].AsInt = Convert-ToGameInt $rent $settings.RentalMultiplier 'RentalMultiplier'
            $rentCount++
        }
        if ($maintenance -ne 0) {
            $machine['maintenanceCost'].AsInt = Convert-ToGameInt $maintenance $settings.MaintenanceMultiplier 'MaintenanceMultiplier'
            $maintenanceCount++
        }
        if ($fuel -ne 0) {
            $machine['fuelCost'].AsInt = Convert-ToGameInt $fuel $settings.FuelMultiplier 'FuelMultiplier'
            $fuelCount++
        }
        if ($delivery -ne 0) {
            $machine['deliveryCost'].AsInt = Convert-ToGameInt $delivery $settings.MachineTransportMultiplier 'MachineTransportMultiplier'
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

    $bulkMultiplier = $settings.BulkMaterialPriceMultiplier
    $economyBase['soilPrize'].AsInt = Convert-ToGameInt 600 $bulkMultiplier 'BulkMaterialPriceMultiplier'
    $economyBase['gravelPrize'].AsInt = Convert-ToGameInt 1000 $bulkMultiplier 'BulkMaterialPriceMultiplier'
    $economyBase['sandPrize'].AsInt = Convert-ToGameInt 750 $bulkMultiplier 'BulkMaterialPriceMultiplier'
    $economyBase['concretePrize'].AsInt = Convert-ToGameInt 500 $bulkMultiplier 'BulkMaterialPriceMultiplier'
    $economyBase['asphaltPrize'].AsInt = Convert-ToGameInt 1500 $bulkMultiplier 'BulkMaterialPriceMultiplier'
    $economyBase['bulkPriceMultiplierHelper'].AsFloat = [single]$settings.InstantFillPriceMultiplier
    $economyBase['cargoTransportCostMultiplierWarehouse'].AsFloat =
        [single](0.10 * $settings.WarehouseDeliveryCostMultiplier)
    $economyBase['cargoTransportCostMultiplierMissionSite'].AsFloat =
        [single](0.15 * $settings.ConstructionSiteDeliveryCostMultiplier)
    $economyBase['craneSetupCost'].AsInt = 25000
    $economyBase['craneTransportCostPerKm'].AsFloat =
        [single](0.003 * $settings.CraneTransportMultiplier)
    $economyBase['characterFastTravelPricePerMeter'].AsFloat =
        [single](0.05 * $settings.FastTravelMultiplier)
    $economyBase['sellPriceMultiplierMachines'].AsFloat =
        [single]($settings.MachineResalePercent / 100.0)
    $economyBase['sellPriceMultiplierCargos'].AsFloat =
        [single]($settings.BuildingMaterialResalePercent / 100.0)
    $economyBase['sellPriceMultiplierBulk'].AsFloat =
        [single]($settings.PhysicalBulkResalePercent / 100.0)
    $economyBase['sellPriceMultiplierBulkHelper'].AsFloat =
        [single]($settings.InstantEmptyPayoutPercent / 100.0)

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
            $cargo['price'].AsInt = Convert-ToGameInt `
                $oldPrice `
                $settings.BuildingMaterialPriceMultiplier `
                'BuildingMaterialPriceMultiplier'
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
        -AssetInfos $economyInfos `
        -BaseFields $economyFields `
        -ClassDatabase $classDatabase

    $bundleReplacements = [System.Collections.Generic.List[AssetsTools.NET.BundleReplacer]]::new()
    $machineEntryName = $bundle.file.GetFileName(0)
    $economyEntryName = $bundle.file.GetFileName(2)
    $machineReplacement = [AssetsTools.NET.BundleReplacerFromMemory]::new(
        $machineEntryName,
        $machineEntryName,
        $true,
        $machineBytes,
        0,
        $machineBytes.Length
    )
    $economyReplacement = [AssetsTools.NET.BundleReplacerFromMemory]::new(
        $economyEntryName,
        $economyEntryName,
        $true,
        $economyBytes,
        0,
        $economyBytes.Length
    )
    $bundleReplacements.Add($machineReplacement)
    $bundleReplacements.Add($economyReplacement)

    foreach ($temporaryPath in @($uncompressedPath, $outputPath)) {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath
        }
    }

    $uncompressedWriter = [AssetsTools.NET.AssetsFileWriter]::new($uncompressedPath)
    try {
        $bundle.file.Write($uncompressedWriter, $bundleReplacements, $classDatabase)
    }
    finally {
        $uncompressedWriter.Dispose()
    }

    $packingManager = [AssetsTools.NET.Extra.AssetsManager]::new()
    try {
        $uncompressedBundle = $packingManager.LoadBundleFile($uncompressedPath, $true)
        $outputWriter = [AssetsTools.NET.AssetsFileWriter]::new($outputPath)
        try {
            $uncompressedBundle.file.Pack(
                $uncompressedBundle.file.DataReader,
                $outputWriter,
                [AssetsTools.NET.AssetBundleCompressionType]::LZ4,
                $false,
                $null
            )
        }
        finally {
            $outputWriter.Dispose()
        }
    }
    finally {
        $packingManager.UnloadAllBundleFiles() | Out-Null
    }

    $outputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath).Hash
    [pscustomobject]@{
        OutputBundle = $outputPath
        OutputSha256 = $outputHash
        RentalValues = $rentCount
        MachinePurchasePrices = $machinePurchasePriceCount
        MaintenanceValues = $maintenanceCount
        FuelValues = $fuelCount
        MachineTransportValues = $deliveryCount
        PurchasableBuildingMaterials = $purchasableCount
    }
}
finally {
    if (Test-Path -LiteralPath $uncompressedPath) {
        Remove-Item -LiteralPath $uncompressedPath
    }
    if ($null -ne $generator) {
        $generator.Dispose()
    }
    if ($null -ne $manager) {
        $manager.UnloadAll($true)
    }
}
