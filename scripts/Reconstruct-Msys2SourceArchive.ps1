[CmdletBinding()]
param(
    [string]$PartsDirectory = $PSScriptRoot,
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\packages\windows\contents\msys2-sonosystem-sources-2026.9.0.parts.json'),
    [Parameter(Mandatory)]
    [string]$OutputZip
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$orderedParts = @($manifest.parts | Sort-Object { [int]$_.number })

if ($orderedParts.Count -ne 3) {
    throw 'Expected exactly three MSYS2 source archive parts.'
}

foreach ($part in $orderedParts) {
    $partPath = Join-Path $PartsDirectory $part.name
    if ((Get-Item -LiteralPath $partPath).Length -ne [long]$part.sizeBytes) {
        throw "Part size mismatch: $($part.name)"
    }
    $partHash = (Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($partHash -cne $part.sha256) {
        throw "Part SHA-256 mismatch: $($part.name)"
    }
}

$outputPath = [IO.Path]::GetFullPath($OutputZip)
if (Test-Path -LiteralPath $outputPath) {
    throw "Refusing to overwrite: $outputPath"
}

$outputStream = [IO.File]::Open($outputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    foreach ($part in $orderedParts) {
        $partPath = Join-Path $PartsDirectory $part.name
        $inputStream = [IO.File]::Open($partPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $inputStream.CopyTo($outputStream, 8MB)
        }
        finally {
            $inputStream.Dispose()
        }
    }
}
finally {
    $outputStream.Dispose()
}

$expected = $manifest.reconstruction
$actualSize = (Get-Item -LiteralPath $outputPath).Length
$actualHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSize -ne [long]$expected.sizeBytes -or $actualHash -cne $expected.sha256) {
    throw 'Reconstructed ZIP does not match the frozen size and SHA-256.'
}

Add-Type -AssemblyName System.IO.Compression
$readStream = [IO.File]::Open($outputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $zip = [IO.Compression.ZipArchive]::new($readStream, [IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        if ($zip.Entries.Count -eq 0) {
            throw 'Reconstructed ZIP contains no entries.'
        }
        [pscustomobject]@{
            Path = $outputPath
            SizeBytes = $actualSize
            Sha256 = $actualHash
            ZipEntryCount = $zip.Entries.Count
        }
    }
    finally {
        $zip.Dispose()
    }
}
finally {
    $readStream.Dispose()
}
