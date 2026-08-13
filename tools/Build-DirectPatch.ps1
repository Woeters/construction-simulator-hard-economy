param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile,

    [Parameter(Mandatory = $true)]
    [string]$TargetFile,

    [Parameter(Mandatory = $true)]
    [string]$PatchFile
)

$ErrorActionPreference = 'Stop'

$sourcePath = (Resolve-Path -LiteralPath $SourceFile).Path
$targetPath = (Resolve-Path -LiteralPath $TargetFile).Path
$patchPath = [System.IO.Path]::GetFullPath($PatchFile)
$patchDirectory = Split-Path -Parent $patchPath

if (-not (Test-Path -LiteralPath $patchDirectory)) {
    New-Item -ItemType Directory -Path $patchDirectory -Force | Out-Null
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public sealed class HardModePatchRange
{
    public long Offset;
    public byte[] Data;
}

public sealed class HardModePatchBuildResult
{
    public string SourceSha256;
    public string TargetSha256;
    public long FileLength;
    public int RangeCount;
    public long ChangedByteCount;
    public long PatchFileLength;
}

public static class HardModeSameLengthPatchBuilder
{
    private static byte[] HexToBytes(string hex)
    {
        byte[] bytes = new byte[hex.Length / 2];
        for (int index = 0; index < bytes.Length; index++)
            bytes[index] = Convert.ToByte(hex.Substring(index * 2, 2), 16);
        return bytes;
    }

    private static string HashFile(string path)
    {
        using (FileStream stream = File.OpenRead(path))
        using (SHA256 sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
    }

    public static HardModePatchBuildResult Build(string sourcePath, string targetPath, string patchPath)
    {
        FileInfo sourceInfo = new FileInfo(sourcePath);
        FileInfo targetInfo = new FileInfo(targetPath);
        if (sourceInfo.Length != targetInfo.Length)
            throw new InvalidOperationException("Source and target files must have exactly the same length.");

        List<HardModePatchRange> ranges = new List<HardModePatchRange>();
        const int bufferSize = 1024 * 1024;
        byte[] sourceBuffer = new byte[bufferSize];
        byte[] targetBuffer = new byte[bufferSize];
        long absoluteOffset = 0;
        long activeStart = -1;
        MemoryStream activeData = null;
        long changedBytes = 0;

        using (FileStream source = File.OpenRead(sourcePath))
        using (FileStream target = File.OpenRead(targetPath))
        {
            while (true)
            {
                int sourceRead = source.Read(sourceBuffer, 0, sourceBuffer.Length);
                int targetRead = target.Read(targetBuffer, 0, targetBuffer.Length);
                if (sourceRead != targetRead)
                    throw new InvalidOperationException("Source and target streams ended at different positions.");
                if (sourceRead == 0)
                    break;

                for (int index = 0; index < sourceRead; index++)
                {
                    bool differs = sourceBuffer[index] != targetBuffer[index];
                    if (differs)
                    {
                        if (activeData == null)
                        {
                            activeStart = absoluteOffset + index;
                            activeData = new MemoryStream();
                        }
                        activeData.WriteByte(targetBuffer[index]);
                        changedBytes++;
                    }
                    else if (activeData != null)
                    {
                        ranges.Add(new HardModePatchRange
                        {
                            Offset = activeStart,
                            Data = activeData.ToArray()
                        });
                        activeData.Dispose();
                        activeData = null;
                        activeStart = -1;
                    }
                }
                absoluteOffset += sourceRead;
            }
        }

        if (activeData != null)
        {
            ranges.Add(new HardModePatchRange
            {
                Offset = activeStart,
                Data = activeData.ToArray()
            });
            activeData.Dispose();
        }

        string sourceHash = HashFile(sourcePath);
        string targetHash = HashFile(targetPath);
        string temporaryPatch = patchPath + ".tmp";
        if (File.Exists(temporaryPatch))
            File.Delete(temporaryPatch);

        using (FileStream output = File.Create(temporaryPatch))
        using (BinaryWriter writer = new BinaryWriter(output, Encoding.UTF8, false))
        {
            writer.Write(Encoding.ASCII.GetBytes("HMP1"));
            writer.Write(sourceInfo.Length);
            writer.Write(HexToBytes(sourceHash));
            writer.Write(HexToBytes(targetHash));
            writer.Write(ranges.Count);
            foreach (HardModePatchRange range in ranges)
            {
                writer.Write(range.Offset);
                writer.Write(range.Data.Length);
                writer.Write(range.Data);
            }
        }

        if (File.Exists(patchPath))
            File.Delete(patchPath);
        File.Move(temporaryPatch, patchPath);

        return new HardModePatchBuildResult
        {
            SourceSha256 = sourceHash,
            TargetSha256 = targetHash,
            FileLength = sourceInfo.Length,
            RangeCount = ranges.Count,
            ChangedByteCount = changedBytes,
            PatchFileLength = new FileInfo(patchPath).Length
        };
    }
}
'@

[HardModeSameLengthPatchBuilder]::Build($sourcePath, $targetPath, $patchPath)
