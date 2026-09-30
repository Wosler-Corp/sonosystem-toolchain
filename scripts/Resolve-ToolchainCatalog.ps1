[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$AssetName,
    [Parameter(Mandatory)][string]$ExpectedSha256,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$GitHubCliPath = 'gh'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = 'Wosler-Corp/sonosystem-toolchain'
if ($ReleaseTag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "Release tag is not a canonical literal: $ReleaseTag"
}
if ([IO.Path]::GetFileName($AssetName) -cne $AssetName -or $AssetName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') {
    throw "Catalog asset name is not a canonical JSON filename: $AssetName"
}
$expectedHash = $ExpectedSha256.ToLowerInvariant()
if ($expectedHash -notmatch '^[a-f0-9]{64}$') {
    throw 'Expected catalog SHA-256 must contain exactly 64 hexadecimal characters.'
}

function Invoke-GitHub {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$Description)
    $output = @(& $GitHubCliPath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub $Description failed (exit $LASTEXITCODE): $([string]::Join([Environment]::NewLine, $output))"
    }
    return $output
}

$viewJson = [string]::Join([Environment]::NewLine, (Invoke-GitHub -Description 'release lookup' -Arguments @(
    'release', 'view', $ReleaseTag, '--repo', $repository, '--json', 'tagName,isDraft,isImmutable'
)))
try { $release = $viewJson | ConvertFrom-Json }
catch { throw "GitHub release metadata is invalid JSON: $($_.Exception.Message)" }
if ([string]$release.tagName -cne $ReleaseTag) { throw "GitHub release tag mismatch: expected '$ReleaseTag'." }
if ([bool]$release.isDraft -or -not [bool]$release.isImmutable) {
    throw "GitHub release '$ReleaseTag' must be published and immutable; drafts are rejected."
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFullPath) { throw "Refusing to overwrite resolved catalog: $outputFullPath" }
$outputParent = Split-Path -Parent $outputFullPath
$operationRoot = Join-Path ([IO.Path]::GetTempPath()) ('toolchain-catalog-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($operationRoot) | Out-Null
try {
    Invoke-GitHub -Description 'catalog download' -Arguments @(
        'release', 'download', $ReleaseTag, '--repo', $repository, '--pattern', $AssetName, '--dir', $operationRoot
    ) | Out-Null
    $downloadedPath = Join-Path $operationRoot $AssetName
    if (-not (Test-Path -LiteralPath $downloadedPath -PathType Leaf)) {
        throw "GitHub release did not produce the exact catalog asset '$AssetName'."
    }
    $unexpected = @(Get-ChildItem -LiteralPath $operationRoot -File | Where-Object Name -CNE $AssetName)
    if ($unexpected.Count -ne 0) { throw 'GitHub release download produced unexpected files.' }

    Invoke-GitHub -Description 'catalog attestation verification' -Arguments @(
        'release', 'verify-asset', $ReleaseTag, $downloadedPath, '--repo', $repository
    ) | Out-Null
    $actualHash = (Get-FileHash -LiteralPath $downloadedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $expectedHash) {
        throw "Catalog SHA-256 mismatch: expected $expectedHash, found $actualHash."
    }

    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\ToolchainCatalog.psm1') -Force
    $catalog = Read-ToolchainCatalog -Path $downloadedPath
    Test-ToolchainCatalog -Catalog $catalog
    foreach ($package in @($catalog.packages)) {
        if ([string]$package.release.repository -cne $repository -or [string]$package.release.tag -cne $ReleaseTag) {
            throw "Catalog package '$($package.id)' does not use the resolved Wosler release tag."
        }
    }

    [IO.Directory]::CreateDirectory($outputParent) | Out-Null
    [IO.File]::Move($downloadedPath, $outputFullPath)
    [pscustomobject][ordered]@{
        catalogId = [string]$catalog.catalogId
        catalogSha256 = $actualHash
        catalogPath = $outputFullPath
        releaseTag = $ReleaseTag
        assetName = $AssetName
    }
} finally {
    Remove-Item -LiteralPath $operationRoot -Recurse -Force -ErrorAction SilentlyContinue
}
