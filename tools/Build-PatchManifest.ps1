param(
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$TargetFile,
    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $repositoryRoot 'patches\GameAssembly.patch.json'
}

$temporaryPatch = Join-Path ([IO.Path]::GetTempPath()) ('HardEconomy-' + [Guid]::NewGuid().ToString('N') + '.hmpatch')
try {
    $result = & (Join-Path $PSScriptRoot 'Build-DirectPatch.ps1') `
        -SourceFile $SourceFile `
        -TargetFile $TargetFile `
        -PatchFile $temporaryPatch

    $stream = [IO.File]::OpenRead($temporaryPatch)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $magic = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne 'HMP1') { throw 'Generated patch has an invalid header.' }
        $fileLength = $reader.ReadInt64()
        $sourceHash = ([BitConverter]::ToString($reader.ReadBytes(32))).Replace('-', '')
        $targetHash = ([BitConverter]::ToString($reader.ReadBytes(32))).Replace('-', '')
        $rangeCount = $reader.ReadInt32()
        $ranges = @()
        for ($index = 0; $index -lt $rangeCount; $index++) {
            $offset = $reader.ReadInt64()
            $length = $reader.ReadInt32()
            $data = $reader.ReadBytes($length)
            if ($data.Length -ne $length) { throw 'Generated patch ended unexpectedly.' }
            $ranges += [ordered]@{
                offset = $offset
                dataHex = ([BitConverter]::ToString($data)).Replace('-', '')
            }
        }
        if ($stream.Position -ne $stream.Length) { throw 'Generated patch contains trailing data.' }
    }
    finally {
        $reader.Dispose()
    }

    $manifest = [ordered]@{
        format = 'HMP1'
        fileLength = $fileLength
        sourceSha256 = $sourceHash
        targetSha256 = $targetHash
        patchSha256 = (Get-FileHash -LiteralPath $temporaryPatch -Algorithm SHA256).Hash
        ranges = $ranges
    }
    $outputPath = [IO.Path]::GetFullPath($OutputFile)
    New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
    [IO.File]::WriteAllText($outputPath, ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

    [pscustomobject]@{
        OutputFile = $outputPath
        SourceSha256 = $sourceHash
        TargetSha256 = $targetHash
        PatchSha256 = $manifest.patchSha256
        RangeCount = $ranges.Count
        ChangedBytes = $result.ChangedByteCount
    }
}
finally {
    Remove-Item -LiteralPath $temporaryPatch -Force -ErrorAction SilentlyContinue
}
