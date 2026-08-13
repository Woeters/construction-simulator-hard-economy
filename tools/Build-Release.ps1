param(
    [Parameter(Mandatory = $true)]
    [string]$UabeaArchive,

    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

$version = '0.2.0'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'build'
}
$archivePath = (Resolve-Path -LiteralPath $UabeaArchive).Path
$buildRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
$stagingRoot = Join-Path $buildRoot 'staging'
$artifactsRoot = Join-Path $buildRoot 'artifacts'
$packageName = "Hard Economy $version Patcher"
$packageRoot = Join-Path $stagingRoot $packageName
$toolsRoot = Join-Path $packageRoot 'tools'
$payloadRoot = Join-Path $packageRoot 'payload'
$zipPath = Join-Path $artifactsRoot "Hard_Economy_${version}_Patcher.zip"

$expectedArchiveHash = '6C5A7FB80B7A7C6433D69A6D2FD37FA4D42E97A9CA01B7CCAF4412D5F3C9AEF6'
$expectedTools = [ordered]@{
    'AssetsTools.NET.dll' = 'E169C2C66EA2D948B42311BAB6C171A1BAC012595CEC9FCC2AEF0C92D06E9D27'
    'AssetsTools.NET.Cpp2IL.dll' = '1F8602203AC7E264D8F0F41B9CC5CA505C74630662F1D575387FE023C92BA4DF'
    'classdata.tpk' = '129E1F80F930415DB6779FE6089AFA75280CB51462BCEE812BEAB6CD81A764C6'
    'LibCpp2IL.dll' = '426082B10961E8E4844CE2AC41D88756E18E636B888C2B9ABC5F9565939BFD82'
    'WasmDisassembler.dll' = 'F487BE8716FF70164F66DC4522197AEB1A86919469FC47E98584BA0FA5D82B86'
}

$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
if ($archiveHash -ne $expectedArchiveHash) {
    throw "UABEA archive hash is $archiveHash; expected $expectedArchiveHash."
}

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $packageRoot, $toolsRoot, $payloadRoot, $artifactsRoot -Force | Out-Null

foreach ($sourceName in @(
    'HardModePatcher.ps1',
    'Apply-HardModeEconomyBundle.ps1',
    'Update-CompanyMilestones.ps1',
    'Apply-HardEconomySaleSettings.ps1',
    'HardEconomy-Settings.txt',
    'Launch Hard Economy Patcher.cmd',
    'README.txt'
)) {
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "src\$sourceName") -Destination (Join-Path $packageRoot $sourceName)
}
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.txt') -Destination (Join-Path $packageRoot 'THIRD_PARTY_NOTICES.txt')

$dependencyRoot = Join-Path $stagingRoot 'uabea-v7'
Expand-Archive -LiteralPath $archivePath -DestinationPath $dependencyRoot -Force

foreach ($toolName in $expectedTools.Keys) {
    $matches = @(Get-ChildItem -LiteralPath $dependencyRoot -Recurse -File -Filter $toolName)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one '$toolName' in the UABEA archive; found $($matches.Count)."
    }

    $actualHash = (Get-FileHash -LiteralPath $matches[0].FullName -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedTools[$toolName]) {
        throw "$toolName hash is $actualHash; expected $($expectedTools[$toolName])."
    }
    Copy-Item -LiteralPath $matches[0].FullName -Destination (Join-Path $toolsRoot $toolName)
}

& (Join-Path $PSScriptRoot 'Build-GameAssemblyPatch.ps1') `
    -ManifestFile (Join-Path $repositoryRoot 'patches\GameAssembly.patch.json') `
    -OutputFile (Join-Path $payloadRoot 'GameAssembly.hmpatch') | Out-Host

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal

[pscustomobject]@{
    Version = $version
    Package = $zipPath
    Sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
}
