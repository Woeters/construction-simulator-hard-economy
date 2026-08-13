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

function Assert-IntArray {
    param(
        [Parameter(Mandatory = $true)]$Field,
        [Parameter(Mandatory = $true)][int[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $actual = @($Field['Array'].Children | ForEach-Object { $_.AsInt })
    if ($actual.Count -ne $Expected.Count) {
        throw "$Label contains $($actual.Count) values; expected $($Expected.Count)."
    }

    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($actual[$index] -ne $Expected[$index]) {
            throw "$Label contains [$($actual -join ', ')]; expected [$($Expected -join ', ')]."
        }
    }
}

function Assert-FloatArray {
    param(
        [Parameter(Mandatory = $true)]$Field,
        [Parameter(Mandatory = $true)][single[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $actual = @($Field['Array'].Children | ForEach-Object { $_.AsFloat })
    if ($actual.Count -ne $Expected.Count) {
        throw "$Label contains $($actual.Count) values; expected $($Expected.Count)."
    }

    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([math]::Abs($actual[$index] - $Expected[$index]) -gt 0.000001) {
            throw "$Label contains [$($actual -join ', ')]; expected [$($Expected -join ', ')]."
        }
    }
}

function Set-IntArray {
    param(
        [Parameter(Mandatory = $true)]$Field,
        [Parameter(Mandatory = $true)][int[]]$Values
    )

    $children = $Field['Array'].Children
    if ($children.Count -ne $Values.Count) {
        throw "Cannot change an integer array from $($children.Count) to $($Values.Count) values."
    }

    for ($index = 0; $index -lt $Values.Count; $index++) {
        $children[$index].AsInt = $Values[$index]
    }
}

function Set-FloatArray {
    param(
        [Parameter(Mandatory = $true)]$Field,
        [Parameter(Mandatory = $true)][single[]]$Values
    )

    $children = $Field['Array'].Children
    if ($children.Count -ne $Values.Count) {
        throw "Cannot change a float array from $($children.Count) to $($Values.Count) values."
    }

    for ($index = 0; $index -lt $Values.Count; $index++) {
        $children[$index].AsFloat = $Values[$index]
    }
}

function Read-Milestone {
    param(
        [Parameter(Mandatory = $true)]$Manager,
        [Parameter(Mandatory = $true)]$AssetsFile,
        [Parameter(Mandatory = $true)][long]$PathId
    )

    $assetInfo = $AssetsFile.file.GetAssetInfo($PathId)
    if ($null -eq $assetInfo) {
        throw "Company milestone asset $PathId was not found."
    }

    $baseField = $Manager.GetBaseField(
        $AssetsFile,
        $assetInfo,
        [AssetsTools.NET.Extra.AssetReadFlags]::None
    )

    return [pscustomobject]@{
        Info = $assetInfo
        Base = $baseField
    }
}

$assetsToolsPath = Join-Path $ToolDirectory 'AssetsTools.NET.dll'
$cpp2IlPath = Join-Path $ToolDirectory 'AssetsTools.NET.Cpp2IL.dll'
$classPackagePath = Join-Path $ToolDirectory 'classdata.tpk'

foreach ($requiredPath in @(
    $InputBundle,
    $assetsToolsPath,
    $cpp2IlPath,
    $classPackagePath,
    $GameAssembly,
    $GlobalMetadata
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file is missing: $requiredPath"
    }
}

Add-Type -Path $assetsToolsPath
Add-Type -Path $cpp2IlPath

$inputPath = (Resolve-Path -LiteralPath $InputBundle).Path
$assemblyPath = (Resolve-Path -LiteralPath $GameAssembly).Path
$metadataPath = (Resolve-Path -LiteralPath $GlobalMetadata).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputBundle)
$uncompressedPath = "$outputPath.uncompressed"

$milestones = @(
    @{
        Name = 'Rent a Machine'
        PathId = [long]39893
        Id = 0
        OldProgress = [int[]](72, 168, 288, 432, 504)
        NewProgress = [int[]](144, 336, 576, 864, 1008)
        OldDiscount = [single[]](0.10, 0.18, 0.24, 0.28, 0.30)
        NewDiscount = [single[]](0.05, 0.09, 0.12, 0.14, 0.15)
    },
    @{
        Name = 'Hey, Taxi!'
        PathId = [long]39688
        Id = 1
        OldProgress = [int[]](20, 40, 60, 80, 100)
        NewProgress = [int[]](100, 200, 300, 400, 500)
        OldDiscount = [single[]](0.10, 0.18, 0.24, 0.28, 0.30)
        NewDiscount = [single[]](0.05, 0.09, 0.12, 0.14, 0.15)
    },
    @{
        Name = 'Soil'
        PathId = [long]39885
        Id = 2
        OldProgress = [int[]](100, 200, 300)
        NewProgress = [int[]](200, 400, 600)
        OldDiscount = [single[]](0.07, 0.12, 0.15)
        NewDiscount = [single[]](0.07, 0.12, 0.15)
    },
    @{
        Name = 'Gravel'
        PathId = [long]39678
        Id = 3
        OldProgress = [int[]](100, 200, 300)
        NewProgress = [int[]](200, 400, 600)
        OldDiscount = [single[]](0.07, 0.12, 0.15)
        NewDiscount = [single[]](0.07, 0.12, 0.15)
    },
    @{
        Name = 'Concrete'
        PathId = [long]39984
        Id = 4
        OldProgress = [int[]](300, 600, 900)
        NewProgress = [int[]](600, 1200, 1800)
        OldDiscount = [single[]](0.07, 0.12, 0.15)
        NewDiscount = [single[]](0.07, 0.12, 0.15)
    },
    @{
        Name = 'Sand'
        PathId = [long]39943
        Id = 5
        OldProgress = [int[]](100, 200, 300)
        NewProgress = [int[]](200, 400, 600)
        OldDiscount = [single[]](0.07, 0.12, 0.15)
        NewDiscount = [single[]](0.07, 0.12, 0.15)
    },
    @{
        Name = 'Asphalt'
        PathId = [long]39841
        Id = 6
        OldProgress = [int[]](100, 200, 300)
        NewProgress = [int[]](200, 400, 600)
        OldDiscount = [single[]](0.07, 0.12, 0.15)
        NewDiscount = [single[]](0.07, 0.12, 0.15)
    },
    @{
        Name = 'Special Components'
        PathId = [long]39827
        Id = 8
        OldProgress = [int[]](10, 20, 30)
        NewProgress = [int[]](15, 30, 45)
        OldDiscount = [single[]](0.07, 0.12, 0.15)
        NewDiscount = [single[]](0.07, 0.12, 0.15)
    }
)

$manager = [AssetsTools.NET.Extra.AssetsManager]::new()
$generator = $null

try {
    $manager.LoadClassPackage($classPackagePath) | Out-Null
    $generator = [AssetsTools.NET.Cpp2IL.Cpp2IlTempGenerator]::new(
        $metadataPath,
        $assemblyPath
    )
    $manager.MonoTempGenerator = $generator

    $bundle = $manager.LoadBundleFile($inputPath, $true)
    $milestoneAssets = $manager.LoadAssetsFileFromBundle($bundle, 0, $true)
    $classDatabase = $manager.LoadClassDatabaseFromPackage(
        $milestoneAssets.file.Metadata.UnityVersion
    )

    $assetReplacements = [System.Collections.Generic.List[AssetsTools.NET.AssetsReplacer]]::new()

    foreach ($milestoneDefinition in $milestones) {
        $milestone = Read-Milestone `
            -Manager $manager `
            -AssetsFile $milestoneAssets `
            -PathId $milestoneDefinition.PathId

        if ($milestone.Base['id'].AsInt -ne $milestoneDefinition.Id) {
            throw "$($milestoneDefinition.Name) has an unexpected internal ID."
        }

        Assert-IntArray `
            -Field $milestone.Base['progressSteps'] `
            -Expected $milestoneDefinition.OldProgress `
            -Label "$($milestoneDefinition.Name) progress"
        Assert-FloatArray `
            -Field $milestone.Base['discountSteps'] `
            -Expected $milestoneDefinition.OldDiscount `
            -Label "$($milestoneDefinition.Name) discount"

        Set-IntArray `
            -Field $milestone.Base['progressSteps'] `
            -Values $milestoneDefinition.NewProgress
        Set-FloatArray `
            -Field $milestone.Base['discountSteps'] `
            -Values $milestoneDefinition.NewDiscount

        $replacement = [AssetsTools.NET.AssetsReplacerFromMemory]::new(
            $milestoneAssets.file,
            $milestone.Info,
            $milestone.Base
        )
        $assetReplacements.Add($replacement)
    }

    $assetsStream = [System.IO.MemoryStream]::new()
    $assetsWriter = [AssetsTools.NET.AssetsFileWriter]::new($assetsStream)
    $milestoneAssets.file.Write(
        $assetsWriter,
        0,
        $assetReplacements,
        $classDatabase
    )
    $assetsWriter.Flush()
    $assetsBytes = $assetsStream.ToArray()
    $assetsWriter.Dispose()
    $assetsStream.Dispose()

    $entryName = $bundle.file.GetFileName(0)
    $bundleReplacement = [AssetsTools.NET.BundleReplacerFromMemory]::new(
        $entryName,
        $entryName,
        $true,
        $assetsBytes,
        0,
        $assetsBytes.Length
    )
    $bundleReplacements = [System.Collections.Generic.List[AssetsTools.NET.BundleReplacer]]::new()
    $bundleReplacements.Add($bundleReplacement)

    if (Test-Path -LiteralPath $uncompressedPath) {
        Remove-Item -LiteralPath $uncompressedPath
    }
    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath
    }

    $uncompressedWriter = [AssetsTools.NET.AssetsFileWriter]::new($uncompressedPath)
    $bundle.file.Write($uncompressedWriter, $bundleReplacements, $classDatabase)
    $uncompressedWriter.Dispose()

    $packingManager = [AssetsTools.NET.Extra.AssetsManager]::new()
    try {
        $uncompressedBundle = $packingManager.LoadBundleFile($uncompressedPath, $true)
        $outputWriter = [AssetsTools.NET.AssetsFileWriter]::new($outputPath)
        $uncompressedBundle.file.Pack(
            $uncompressedBundle.file.DataReader,
            $outputWriter,
            [AssetsTools.NET.AssetBundleCompressionType]::LZ4,
            $false,
            $null
        )
        $outputWriter.Dispose()
    }
    finally {
        $packingManager.UnloadAllBundleFiles() | Out-Null
    }

    Remove-Item -LiteralPath $uncompressedPath

    foreach ($replacement in $assetReplacements) {
        $replacement.Dispose()
    }

    [pscustomobject]@{
        OutputBundle = $outputPath
        ChangedMilestones = $milestones.Count
        PalletsChanged = $false
        OutputSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath).Hash
    }
}
finally {
    if ($null -ne $generator) {
        $generator.Dispose()
    }
    if ($null -ne $manager) {
        $manager.UnloadAll($true)
    }
}
