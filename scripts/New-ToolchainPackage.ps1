[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DefinitionPath,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-DirectorySourceIdentity {
    param([Parameter(Mandatory)][string]$Path)

    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $records = [Collections.Generic.List[string]]::new()
    $size = 0L
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Source contains a reparse point: $($file.FullName)" }
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $records.Add("$relative`0$hash`0$($file.Length)")
        $size += $file.Length
    }
    if ($records.Count -eq 0) { throw 'ZIP source directory must contain at least one file.' }
    $recordArray = $records.ToArray()
    [Array]::Sort($recordArray, [StringComparer]::Ordinal)
    $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes([string]::Join("`n", $recordArray))
    return [pscustomobject]@{
        Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant()
        SizeBytes = $size
        Files = $recordArray
    }
}

function Get-FileSourceIdentity {
    param([Parameter(Mandatory)][string]$Path)
    return [pscustomobject]@{
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        SizeBytes = (Get-Item -LiteralPath $Path).Length
    }
}

function Assert-OutputOutsideWorkingTree {
    param([Parameter(Mandatory)][string]$Path)

    $gitRootOutput = & git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the Git working tree for package-output safety validation.' }
    $gitRoot = [IO.Path]::GetFullPath(([string]$gitRootOutput).Trim()).TrimEnd('\', '/')
    $output = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($output -eq $gitRoot -or $output.StartsWith("$gitRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Binary package output is forbidden inside the Git working tree: $output"
    }
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $sourceRoot = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\', '/')
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse)) {
        $paths.Add($file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/'))
    }
    $pathArray = $paths.ToArray()
    [Array]::Sort($pathArray, [StringComparer]::Ordinal)

    $stream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($relativePath in $pathArray) {
                $entry = $archive.CreateEntry($relativePath, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [datetimeoffset]'2000-01-01T00:00:00Z'
                $entry.ExternalAttributes = 0
                $entryStream = $entry.Open()
                try {
                    $sourceStream = [IO.File]::OpenRead((Join-Path $sourceRoot $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
                    try { $sourceStream.CopyTo($entryStream) } finally { $sourceStream.Dispose() }
                } finally { $entryStream.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function Assert-AuthenticodeExpectation {
    param([Parameter(Mandatory)]$Expectation, [Parameter(Mandatory)][string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -cne [string]$Expectation.status) {
        throw "Authenticode signature mismatch for '$Path': expected $($Expectation.status), found $($signature.Status)."
    }
    if ($null -ne $Expectation.PSObject.Properties['signerSubject'] -and [string]$signature.SignerCertificate.Subject -cne [string]$Expectation.signerSubject) {
        throw "Authenticode signer mismatch for '$Path'."
    }
}

function Get-InfContentFromSource {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$InfPath)

    if (Test-Path -LiteralPath $Path -PathType Container) {
        return Get-Content -LiteralPath (Join-Path $Path $InfPath) -Raw
    }
    if ([IO.Path]::GetExtension($Path) -ine '.zip') { throw "INF validation requires a source directory or ZIP archive: $Path" }
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $normalized = $InfPath.Replace('\', '/')
        $entry = @($archive.Entries | Where-Object { $_.FullName -ceq $normalized } | Select-Object -First 1)[0]
        if ($null -eq $entry) { throw "INF '$InfPath' is missing from source archive." }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}

$validatorPath = Join-Path $PSScriptRoot 'Test-PackageDefinition.ps1'
$definition = & $validatorPath -DefinitionPath $DefinitionPath
Assert-OutputOutsideWorkingTree -Path $OutputDirectory

$kind = [string]$definition.kind
if ($kind -ceq 'zip') {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { throw "ZIP package source must be a directory: $SourcePath" }
    $sourceIdentity = Get-DirectorySourceIdentity -Path $SourcePath
} else {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "$kind package source must be a file: $SourcePath" }
    $sourceIdentity = Get-FileSourceIdentity -Path $SourcePath
}

if ([long]$sourceIdentity.SizeBytes -ne [long]$definition.source.sizeBytes) {
    throw "Package '$($definition.id)' source size mismatch: expected $($definition.source.sizeBytes), found $($sourceIdentity.SizeBytes)."
}
if ([string]$sourceIdentity.Sha256 -cne [string]$definition.source.sha256) {
    throw "Package '$($definition.id)' source SHA-256 mismatch."
}
if ($null -ne $definition.source.PSObject.Properties['authenticode']) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw 'Authenticode validation requires a file source.' }
    Assert-AuthenticodeExpectation -Expectation $definition.source.authenticode -Path $SourcePath
}
if ($null -ne $definition.source.PSObject.Properties['inf']) {
    $inf = $definition.source.inf
    $content = Get-InfContentFromSource -Path $SourcePath -InfPath ([string]$inf.path)
    if ($content -notmatch "(?im)^Provider\s*=\s*.*$([regex]::Escape([string]$inf.provider))") { throw "INF provider mismatch for '$($inf.path)'." }
    if ($content -notmatch "(?im)^DriverVer\s*=.*,$([regex]::Escape([string]$inf.version))\s*$") { throw "INF version mismatch for '$($inf.path)'." }
}

[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$assetPath = Join-Path $OutputDirectory ([string]$definition.asset)
$temporaryAsset = "$assetPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    if ($kind -ceq 'zip') {
        New-DeterministicZip -SourceDirectory $SourcePath -OutputPath $temporaryAsset
    } else {
        [IO.File]::Copy($SourcePath, $temporaryAsset, $false)
    }
    [IO.File]::Move($temporaryAsset, $assetPath, $true)
} finally {
    if (Test-Path -LiteralPath $temporaryAsset) { Remove-Item -LiteralPath $temporaryAsset -Force }
}

$assetHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
$assetSize = (Get-Item -LiteralPath $assetPath).Length
$checksum = "$assetHash  $($definition.asset)`n"
[IO.File]::WriteAllText("$assetPath.sha256", $checksum, [Text.UTF8Encoding]::new($false))

$provenance = [ordered]@{
    schemaVersion = 1
    package = [ordered]@{
        id = [string]$definition.id
        version = [string]$definition.version
        kind = $kind
    }
    asset = [ordered]@{
        name = [string]$definition.asset
        sha256 = $assetHash
        sizeBytes = $assetSize
    }
    source = [ordered]@{
        sha256 = [string]$definition.source.sha256
        sizeBytes = [long]$definition.source.sizeBytes
    }
    upstream = $definition.upstream
    licenses = @($definition.licenses)
}
[IO.File]::WriteAllText("$assetPath.provenance.json", ($provenance | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
Write-Output $provenance
