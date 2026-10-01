[CmdletBinding()]
param([Parameter(Mandatory)][string]$DefinitionPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredProperty {
    param($Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Context)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { throw "$Context is missing required property '$Name'." }
    return $property.Value
}

function Assert-NonEmptyString {
    param($Value, [Parameter(Mandatory)][string]$Context)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "$Context must be a non-empty string." }
}

function Assert-SafeRelativePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Context)
    Assert-NonEmptyString -Value $Path -Context $Context
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:' -or @($Path -split '[\\/]') -contains '..') {
        throw "$Context must be a safe relative path: $Path"
    }
}

if (-not (Test-Path -LiteralPath $DefinitionPath -PathType Leaf)) { throw "Package definition does not exist: $DefinitionPath" }
try {
    $definition = Get-Content -LiteralPath $DefinitionPath -Raw | ConvertFrom-Json -Depth 100
} catch {
    throw "Package definition is not valid JSON: $DefinitionPath. $($_.Exception.Message)"
}

if ((Get-RequiredProperty -Object $definition -Name 'schemaVersion' -Context 'definition') -ne 1) {
    throw "Package definition schemaVersion must be 1."
}
$id = [string](Get-RequiredProperty -Object $definition -Name 'id' -Context 'definition')
if ($id -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { throw "Package definition id is invalid: $id" }
$version = [string](Get-RequiredProperty -Object $definition -Name 'version' -Context "package '$id'")
if ($version -cnotmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Package '$id' version must be exact semantic version." }
$kind = [string](Get-RequiredProperty -Object $definition -Name 'kind' -Context "package '$id'")
if ($kind -cnotin @('zip', 'msi', 'exe', 'driver')) { throw "Package '$id' kind '$kind' is unsupported." }
$asset = [string](Get-RequiredProperty -Object $definition -Name 'asset' -Context "package '$id'")
Assert-SafeRelativePath -Path $asset -Context "Package '$id' asset"
if ($asset -match '[\\/]') { throw "Package '$id' asset must be a filename." }

$source = Get-RequiredProperty -Object $definition -Name 'source' -Context "package '$id'"
$sourceHash = [string](Get-RequiredProperty -Object $source -Name 'sha256' -Context "package '$id' source")
if ($sourceHash -cnotmatch '^[0-9a-f]{64}$') { throw "Package '$id' source sha256 must contain 64 lowercase hexadecimal characters." }
$sourceSize = 0L
if (-not [long]::TryParse([string](Get-RequiredProperty -Object $source -Name 'sizeBytes' -Context "package '$id' source"), [ref]$sourceSize) -or $sourceSize -le 0) {
    throw "Package '$id' source sizeBytes must be a positive integer."
}
if ($null -ne $source.PSObject.Properties['authenticode']) {
    $status = [string](Get-RequiredProperty -Object $source.authenticode -Name 'status' -Context "package '$id' source authenticode")
    if ($status -cne 'Valid') { throw "Package '$id' Authenticode expectation must require status 'Valid'." }
    if ($null -ne $source.authenticode.PSObject.Properties['signerSubject']) {
        Assert-NonEmptyString -Value $source.authenticode.signerSubject -Context "package '$id' Authenticode signerSubject"
    }
}
if ($null -ne $source.PSObject.Properties['inf']) {
    $inf = $source.inf
    Assert-SafeRelativePath -Path ([string](Get-RequiredProperty -Object $inf -Name 'path' -Context "package '$id' source inf")) -Context "package '$id' INF path"
    Assert-NonEmptyString -Value (Get-RequiredProperty -Object $inf -Name 'provider' -Context "package '$id' source inf") -Context "package '$id' INF provider"
    Assert-NonEmptyString -Value (Get-RequiredProperty -Object $inf -Name 'version' -Context "package '$id' source inf") -Context "package '$id' INF version"
}

$upstream = Get-RequiredProperty -Object $definition -Name 'upstream' -Context "package '$id'"
$url = [string](Get-RequiredProperty -Object $upstream -Name 'url' -Context "package '$id' upstream")
$uri = $null
if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
    throw "Package '$id' upstream url must be an absolute HTTP(S) URI."
}
Assert-NonEmptyString -Value (Get-RequiredProperty -Object $upstream -Name 'version' -Context "package '$id' upstream") -Context "package '$id' upstream version"
$retrievedAt = [datetimeoffset]::MinValue
if (-not [datetimeoffset]::TryParse([string](Get-RequiredProperty -Object $upstream -Name 'retrievedAt' -Context "package '$id' upstream"), [ref]$retrievedAt)) {
    throw "Package '$id' upstream retrievedAt must be a timestamp."
}

$licenses = @(Get-RequiredProperty -Object $definition -Name 'licenses' -Context "package '$id'")
if ($licenses.Count -eq 0) { throw "Package '$id' licenses must not be empty." }
foreach ($license in $licenses) {
    Assert-SafeRelativePath -Path ([string]$license) -Context "Package '$id' license"
    if ([string]$license -cnotmatch '^licenses[\\/]') { throw "Package '$id' license must be under licenses/: $license" }
}

Write-Output $definition
