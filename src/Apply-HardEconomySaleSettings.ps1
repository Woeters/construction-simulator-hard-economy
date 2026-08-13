param(
    [Parameter(Mandatory = $true)]
    [string]$SourceGameAssembly,

    [Parameter(Mandatory = $true)]
    [string]$OutputGameAssembly,

    [Parameter(Mandatory = $true)]
    [string]$SettingsFile
)

$ErrorActionPreference = 'Stop'

$RequiredSettingNames = @(
    'BuildingMaterialSaleMaxActive',
    'BuildingMaterialSaleHourlyChancePercent',
    'VehicleSaleMaxActive',
    'VehicleSaleHourlyChancePercent'
)

# These are the four compact, already-tested values inside the two sale
# schedulers. The building-material cache is moved to a dedicated local data
# section when needed, so both kinds of sale can safely track up to 22 items.
$MaterialChanceRaw = 0x1550D
$MaterialCapRaw = 0x1AB7F
$VehicleChanceRaw = 0x18C3B
$VehicleCapRaw = 0x17354
$MaterialTimelineLeaRaw = 0x1AB39
$VehicleTimelineLeaRaw = 0x1730E
$OriginalMaterialCacheRva = 0x11B92080
$OriginalVehicleCacheRva = 0x11B920E0
$MaterialCacheSectionName = '.hesale'
$MaterialCacheSize = 0x1000
$MaterialCacheOffset = 0x000
$VehicleCacheOffset = 0x400
$MaximumSaleEntries = 50

function Read-SaleSettings {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Settings file is missing: $Path"
    }

    $values = @{}
    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }
        if ($line -notmatch '^([A-Za-z][A-Za-z0-9]*)\s*=\s*(.+)$') {
            continue
        }
        $name = $matches[1]
        if ($name -notin $RequiredSettingNames) {
            continue
        }
        if ($values.ContainsKey($name)) {
            throw "Sale setting '$name' occurs more than once."
        }
        $textValue = ($matches[2] -split '\s+#', 2)[0].Trim()
        if ($textValue.Contains(',')) {
            throw "Invalid value for '$name' on line $lineNumber. Use a decimal point, not a comma."
        }
        $number = 0.0
        $parsed = [double]::TryParse(
            $textValue,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        )
        if (-not $parsed -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            throw "Invalid value for '$name' on line $lineNumber."
        }
        $values[$name] = $number
    }

    foreach ($name in $RequiredSettingNames) {
        if (-not $values.ContainsKey($name)) {
            throw "Required sale setting '$name' is missing."
        }
    }
    return $values
}

function Get-WholeNumberSetting {
    param(
        [Parameter(Mandatory = $true)][double]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][int]$Maximum
    )

    $rounded = [math]::Round($Value, 0, [MidpointRounding]::AwayFromZero)
    if ([math]::Abs($Value - $rounded) -gt 0.000001) {
        throw "$Name must be a whole number."
    }
    if ($rounded -lt $Minimum -or $rounded -gt $Maximum) {
        throw "$Name must be between $Minimum and $Maximum."
    }
    return [int]$rounded
}

function Get-HourlyChanceEncoding {
    param(
        [Parameter(Mandatory = $true)][double]$Percent,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Percent -lt 0 -or $Percent -gt 50) {
        throw "$Name must be between 0 and 50 percent."
    }

    # For lower chances, a 1,024-value roll keeps the existing 8% vehicle
    # default almost exact. Higher chances use a 256-value roll because the
    # scheduler's compact comparison can only encode thresholds through 127.
    if ($Percent -lt 12.5) {
        $threshold = [int][math]::Round(($Percent / 100.0) * 1024.0, 0, [MidpointRounding]::AwayFromZero)
        if ($threshold -gt 127) { throw "$Name cannot be encoded safely." }
        return [pscustomobject]@{ MaskLowByte = 0xFF; MaskHighByte = 0x03; Threshold = $threshold; ActualPercent = (100.0 * $threshold / 1024.0) }
    }

    if ([math]::Abs($Percent - 50.0) -lt 0.000001) {
        return [pscustomobject]@{ MaskLowByte = 0x7F; MaskHighByte = 0x00; Threshold = 64; ActualPercent = 50.0 }
    }

    $threshold = [int][math]::Round(($Percent / 100.0) * 256.0, 0, [MidpointRounding]::AwayFromZero)
    if ($threshold -gt 127) { $threshold = 127 }
    return [pscustomobject]@{ MaskLowByte = 0xFF; MaskHighByte = 0x00; Threshold = $threshold; ActualPercent = (100.0 * $threshold / 256.0) }
}

function Assert-ChanceSequence {
    param([byte[]]$Data, [int]$Offset, [string]$Label)

    $expected = [byte[]](0x8B, 0xC3, 0x25, 0xFF, 0x00, 0x00, 0x00, 0x83, 0xF8, 0x00, 0x0F, 0x83)
    for ($index = 0; $index -lt $expected.Length; $index++) {
        if ($index -in @(3, 4, 9)) { continue }
        if ($Data[$Offset + $index] -ne $expected[$index]) {
            throw "$Label does not match the tested Hard Economy sale scheduler."
        }
    }
    $lowMask = $Data[$Offset + 3]
    $highMask = $Data[$Offset + 4]
    if (-not (
        ($lowMask -eq 0xFF -and $highMask -in @(0x00, 0x03)) -or
        ($lowMask -eq 0x7F -and $highMask -eq 0x00) -or
        ($lowMask -eq 0x00 -and $highMask -eq 0x00)
    )) {
        throw "$Label has an unsupported chance-mask encoding."
    }
}

function Align-Up {
    param([int]$Value, [int]$Alignment)
    return [int]([math]::Ceiling($Value / [double]$Alignment) * $Alignment)
}

function Get-OrAdd-MaterialSaleCacheSection {
    param([Parameter(Mandatory = $true)][byte[]]$Data)

    $peOffset = [BitConverter]::ToInt32($Data, 0x3C)
    if ([Text.Encoding]::ASCII.GetString($Data, $peOffset, 4) -ne 'PE' + [char]0 + [char]0) {
        throw 'GameAssembly.dll does not contain a supported PE header.'
    }
    $sectionCount = [BitConverter]::ToUInt16($Data, $peOffset + 6)
    $optionalHeaderSize = [BitConverter]::ToUInt16($Data, $peOffset + 20)
    $optionalHeader = $peOffset + 24
    $sectionTable = $optionalHeader + $optionalHeaderSize
    $sizeOfHeaders = [BitConverter]::ToInt32($Data, $optionalHeader + 0x3C)
    $sectionAlignment = [BitConverter]::ToInt32($Data, $optionalHeader + 0x20)
    $fileAlignment = [BitConverter]::ToInt32($Data, $optionalHeader + 0x24)

    $highestRawEnd = 0
    $highestVirtualEnd = 0
    for ($index = 0; $index -lt $sectionCount; $index++) {
        $header = $sectionTable + (40 * $index)
        $name = [Text.Encoding]::ASCII.GetString($Data, $header, 8).Trim([char]0)
        $virtualSize = [BitConverter]::ToInt32($Data, $header + 8)
        $virtualAddress = [BitConverter]::ToInt32($Data, $header + 12)
        $rawSize = [BitConverter]::ToInt32($Data, $header + 16)
        $rawAddress = [BitConverter]::ToInt32($Data, $header + 20)
        if ($name -eq $MaterialCacheSectionName) {
            if ($rawSize -lt $MaterialCacheSize -or $virtualSize -lt $MaterialCacheSize) {
                throw 'Existing Hard Economy sale-cache section is too small.'
            }
            return [pscustomobject]@{ Bytes = $Data; Raw = $rawAddress; Rva = $virtualAddress }
        }
        $highestRawEnd = [math]::Max($highestRawEnd, $rawAddress + $rawSize)
        $highestVirtualEnd = [math]::Max($highestVirtualEnd, $virtualAddress + [math]::Max($virtualSize, $rawSize))
    }

    $newHeader = $sectionTable + (40 * $sectionCount)
    if ($newHeader + 40 -gt $sizeOfHeaders) {
        throw 'There is no safe room in the PE header for the Hard Economy sale-cache section.'
    }
    for ($index = 0; $index -lt 40; $index++) {
        if ($Data[$newHeader + $index] -ne 0) {
            throw 'The next PE section-header slot is unexpectedly in use.'
        }
    }

    $newRaw = Align-Up ([math]::Max($highestRawEnd, $Data.Length)) $fileAlignment
    $newRva = Align-Up $highestVirtualEnd $sectionAlignment
    $newLength = $newRaw + $MaterialCacheSize
    $expanded = New-Object byte[] $newLength
    [Array]::Copy($Data, $expanded, $Data.Length)

    [Text.Encoding]::ASCII.GetBytes($MaterialCacheSectionName).CopyTo($expanded, $newHeader)
    [BitConverter]::GetBytes([int]$MaterialCacheSize).CopyTo($expanded, $newHeader + 8)
    [BitConverter]::GetBytes([int]$newRva).CopyTo($expanded, $newHeader + 12)
    [BitConverter]::GetBytes([int]$MaterialCacheSize).CopyTo($expanded, $newHeader + 16)
    [BitConverter]::GetBytes([int]$newRaw).CopyTo($expanded, $newHeader + 20)
    [BitConverter]::GetBytes([uint32]3221225536).CopyTo($expanded, $newHeader + 36)
    [BitConverter]::GetBytes([uint16]($sectionCount + 1)).CopyTo($expanded, $peOffset + 6)
    [BitConverter]::GetBytes((Align-Up ($newRva + $MaterialCacheSize) $sectionAlignment)).CopyTo($expanded, $optionalHeader + 0x38)

    return [pscustomobject]@{ Bytes = $expanded; Raw = $newRaw; Rva = $newRva }
}

function Update-MaterialSaleCacheReference {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Data,
        [Parameter(Mandatory = $true)][int]$NewCacheRva
    )

    if ($Data[$MaterialTimelineLeaRaw] -ne 0x48 -or $Data[$MaterialTimelineLeaRaw + 1] -ne 0x8D -or $Data[$MaterialTimelineLeaRaw + 2] -ne 0x35) {
        throw 'Building-material sale scheduler does not contain the tested cache reference.'
    }

    # This instruction is in the original .debug code section. Its tested RVA
    # is fixed for the supported game build.
    $instructionRva = 0x1B539
    $oldDisplacement = [BitConverter]::ToInt32($Data, $MaterialTimelineLeaRaw + 3)
    $oldTargetRva = $instructionRva + 7 + $oldDisplacement
    if ($oldTargetRva -notin @($OriginalMaterialCacheRva, $NewCacheRva)) {
        throw 'Building-material sale scheduler points at an unexpected cache location.'
    }

    $newDisplacement = [int]$NewCacheRva - ($instructionRva + 7)
    [BitConverter]::GetBytes([int]$newDisplacement).CopyTo($Data, $MaterialTimelineLeaRaw + 3)
    $verifiedTargetRva = $instructionRva + 7 + [BitConverter]::ToInt32($Data, $MaterialTimelineLeaRaw + 3)
    if ($verifiedTargetRva -ne $NewCacheRva) {
        throw 'Building-material sale cache reference failed validation.'
    }
}

function Update-VehicleSaleCacheReference {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Data,
        [Parameter(Mandatory = $true)][int]$NewCacheRva
    )

    if ($Data[$VehicleTimelineLeaRaw] -ne 0x48 -or $Data[$VehicleTimelineLeaRaw + 1] -ne 0x8D -or $Data[$VehicleTimelineLeaRaw + 2] -ne 0x35) {
        throw 'Vehicle sale scheduler does not contain the tested cache reference.'
    }

    $instructionRva = 0x17D0E
    $oldDisplacement = [BitConverter]::ToInt32($Data, $VehicleTimelineLeaRaw + 3)
    $oldTargetRva = $instructionRva + 7 + $oldDisplacement
    if ($oldTargetRva -notin @($OriginalVehicleCacheRva, $NewCacheRva)) {
        throw 'Vehicle sale scheduler points at an unexpected cache location.'
    }

    $newDisplacement = [int]$NewCacheRva - ($instructionRva + 7)
    [BitConverter]::GetBytes([int]$newDisplacement).CopyTo($Data, $VehicleTimelineLeaRaw + 3)
    $verifiedTargetRva = $instructionRva + 7 + [BitConverter]::ToInt32($Data, $VehicleTimelineLeaRaw + 3)
    if ($verifiedTargetRva -ne $NewCacheRva) {
        throw 'Vehicle sale cache reference failed validation.'
    }
}

function Assert-CapSequence {
    param([byte[]]$Data, [int]$Offset, [int]$Maximum, [string]$Label)

    if (
        $Data[$Offset] -ne 0x83 -or
        $Data[$Offset + 1] -ne 0xF8 -or
        $Data[$Offset + 3] -ne 0x0F -or
        $Data[$Offset + 4] -ne 0x8D
    ) {
        throw "$Label does not match the tested Hard Economy sale scheduler."
    }
    if ($Data[$Offset + 2] -gt $Maximum) {
        throw "$Label has an unsupported active-sale maximum."
    }
}

$settings = Read-SaleSettings $SettingsFile
$materialMaximum = Get-WholeNumberSetting $settings.BuildingMaterialSaleMaxActive 'BuildingMaterialSaleMaxActive' 0 50
$vehicleMaximum = Get-WholeNumberSetting $settings.VehicleSaleMaxActive 'VehicleSaleMaxActive' 0 50
$materialChance = Get-HourlyChanceEncoding $settings.BuildingMaterialSaleHourlyChancePercent 'BuildingMaterialSaleHourlyChancePercent'
$vehicleChance = Get-HourlyChanceEncoding $settings.VehicleSaleHourlyChancePercent 'VehicleSaleHourlyChancePercent'

$sourcePath = (Resolve-Path -LiteralPath $SourceGameAssembly).Path
$sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
Assert-ChanceSequence $sourceBytes $MaterialChanceRaw 'Building-material sale chance'
Assert-CapSequence $sourceBytes $MaterialCapRaw 50 'Building-material sale maximum'
Assert-ChanceSequence $sourceBytes $VehicleChanceRaw 'Vehicle sale chance'
Assert-CapSequence $sourceBytes $VehicleCapRaw 50 'Vehicle sale maximum'

$candidatePath = [IO.Path]::GetFullPath($OutputGameAssembly)
Copy-Item -LiteralPath $sourcePath -Destination $candidatePath -Force
$candidateBytes = [IO.File]::ReadAllBytes($candidatePath)
$materialCacheSection = Get-OrAdd-MaterialSaleCacheSection $candidateBytes
$candidateBytes = $materialCacheSection.Bytes
$requiredCacheBytes = 16 + (12 * $MaximumSaleEntries)
for ($index = 0; $index -lt $requiredCacheBytes; $index++) {
    if ($candidateBytes[$materialCacheSection.Raw + $MaterialCacheOffset + $index] -ne 0) {
        throw 'Hard Economy material-sale cache is unexpectedly not empty.'
    }
    if ($candidateBytes[$materialCacheSection.Raw + $VehicleCacheOffset + $index] -ne 0) {
        throw 'Hard Economy vehicle-sale cache is unexpectedly not empty.'
    }
}
Update-MaterialSaleCacheReference $candidateBytes ($materialCacheSection.Rva + $MaterialCacheOffset)
Update-VehicleSaleCacheReference $candidateBytes ($materialCacheSection.Rva + $VehicleCacheOffset)

$candidateBytes[$MaterialChanceRaw + 3] = $materialChance.MaskLowByte
$candidateBytes[$MaterialChanceRaw + 4] = $materialChance.MaskHighByte
$candidateBytes[$MaterialChanceRaw + 9] = $materialChance.Threshold
$candidateBytes[$MaterialCapRaw + 2] = [byte]$materialMaximum
$candidateBytes[$VehicleChanceRaw + 3] = $vehicleChance.MaskLowByte
$candidateBytes[$VehicleChanceRaw + 4] = $vehicleChance.MaskHighByte
$candidateBytes[$VehicleChanceRaw + 9] = $vehicleChance.Threshold
$candidateBytes[$VehicleCapRaw + 2] = [byte]$vehicleMaximum

Assert-ChanceSequence $candidateBytes $MaterialChanceRaw 'Updated building-material sale chance'
Assert-CapSequence $candidateBytes $MaterialCapRaw 50 'Updated building-material sale maximum'
Assert-ChanceSequence $candidateBytes $VehicleChanceRaw 'Updated vehicle sale chance'
Assert-CapSequence $candidateBytes $VehicleCapRaw 50 'Updated vehicle sale maximum'
if ($candidateBytes[$MaterialChanceRaw + 3] -ne $materialChance.MaskLowByte -or $candidateBytes[$MaterialChanceRaw + 4] -ne $materialChance.MaskHighByte -or $candidateBytes[$MaterialChanceRaw + 9] -ne $materialChance.Threshold) { throw 'Building-material sale chance update failed validation.' }
if ($candidateBytes[$MaterialCapRaw + 2] -ne $materialMaximum) { throw 'Building-material sale maximum update failed validation.' }
if ($candidateBytes[$VehicleChanceRaw + 3] -ne $vehicleChance.MaskLowByte -or $candidateBytes[$VehicleChanceRaw + 4] -ne $vehicleChance.MaskHighByte -or $candidateBytes[$VehicleChanceRaw + 9] -ne $vehicleChance.Threshold) { throw 'Vehicle sale chance update failed validation.' }
if ($candidateBytes[$VehicleCapRaw + 2] -ne $vehicleMaximum) { throw 'Vehicle sale maximum update failed validation.' }

[IO.File]::WriteAllBytes($candidatePath, $candidateBytes)

[pscustomobject]@{
    OutputGameAssembly = $candidatePath
    OutputSha256 = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
    BuildingMaterialSaleMaxActive = $materialMaximum
    BuildingMaterialSaleHourlyChancePercent = [math]::Round($materialChance.ActualPercent, 3)
    VehicleSaleMaxActive = $vehicleMaximum
    VehicleSaleHourlyChancePercent = [math]::Round($vehicleChance.ActualPercent, 3)
}
