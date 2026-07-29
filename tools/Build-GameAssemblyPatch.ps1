param(
    [string]$ManifestFile,
    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($ManifestFile)) {
    $ManifestFile = Join-Path $repositoryRoot 'patches\GameAssembly.patch.json'
}
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $repositoryRoot 'build\GameAssembly.hmpatch'
}

function Convert-HexToBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hex
    )

    if ($Hex.Length % 2 -ne 0 -or $Hex -notmatch '^[0-9A-Fa-f]+$') {
        throw 'A patch manifest contains invalid hexadecimal data.'
    }

    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return $bytes
}

$manifestPath = (Resolve-Path -LiteralPath $ManifestFile).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputFile)
$outputDirectory = Split-Path -Parent $outputPath
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if ($manifest.format -ne 'HMP1') {
    throw "Unsupported patch format '$($manifest.format)'."
}
if ([long]$manifest.fileLength -le 0) {
    throw 'The patch manifest contains an invalid target file length.'
}
foreach ($hashName in @('sourceSha256', 'targetSha256', 'patchSha256')) {
    if ([string]$manifest.$hashName -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "The patch manifest contains an invalid $hashName value."
    }
}
if ($null -eq $manifest.ranges -or $manifest.ranges.Count -le 0) {
    throw 'The patch manifest does not contain any byte ranges.'
}

$preparedRanges = @()
$previousEnd = 0L
foreach ($range in $manifest.ranges) {
    $offset = [long]$range.offset
    $data = Convert-HexToBytes ([string]$range.dataHex)
    $end = $offset + $data.Length

    if ($offset -lt 0 -or $end -gt [long]$manifest.fileLength) {
        throw "Patch range at offset $offset is outside the target file."
    }
    if ($preparedRanges.Count -gt 0 -and $offset -lt $previousEnd) {
        throw "Patch range at offset $offset overlaps an earlier range."
    }

    $preparedRanges += [pscustomobject]@{
        Offset = $offset
        Data = $data
    }
    $previousEnd = $end
}

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$temporaryPath = "$outputPath.tmp"
if (Test-Path -LiteralPath $temporaryPath) {
    Remove-Item -LiteralPath $temporaryPath -Force
}

$stream = [System.IO.File]::Create($temporaryPath)
$writer = New-Object System.IO.BinaryWriter($stream, [System.Text.Encoding]::UTF8, $false)
try {
    $magic = [System.Text.Encoding]::ASCII.GetBytes('HMP1')
    $writer.Write($magic, 0, $magic.Length)
    $writer.Write([long]$manifest.fileLength)
    $sourceHash = Convert-HexToBytes ([string]$manifest.sourceSha256)
    $targetHash = Convert-HexToBytes ([string]$manifest.targetSha256)
    $writer.Write($sourceHash, 0, $sourceHash.Length)
    $writer.Write($targetHash, 0, $targetHash.Length)
    $writer.Write([int]$preparedRanges.Count)

    foreach ($range in $preparedRanges) {
        $writer.Write([long]$range.Offset)
        $writer.Write([int]$range.Data.Length)
        $writer.Write([byte[]]$range.Data, 0, $range.Data.Length)
    }
}
finally {
    $writer.Dispose()
}

$actualHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash
if ($actualHash -ne ([string]$manifest.patchSha256).ToUpperInvariant()) {
    Remove-Item -LiteralPath $temporaryPath -Force
    throw "Generated patch hash is $actualHash; expected $($manifest.patchSha256)."
}

if (Test-Path -LiteralPath $outputPath) {
    Remove-Item -LiteralPath $outputPath -Force
}
Move-Item -LiteralPath $temporaryPath -Destination $outputPath

[pscustomobject]@{
    OutputFile = $outputPath
    Sha256 = $actualHash
    RangeCount = $preparedRanges.Count
    ChangedBytes = ($preparedRanges | ForEach-Object { $_.Data.Length } | Measure-Object -Sum).Sum
}
