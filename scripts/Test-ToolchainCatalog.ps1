[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CatalogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src\ToolchainCatalog.psm1'
Import-Module $modulePath -Force

$catalog = Read-ToolchainCatalog -Path $CatalogPath
Test-ToolchainCatalog -Catalog $catalog

foreach ($profile in @($catalog.profiles.PSObject.Properties.Name)) {
    $packages = @(Resolve-ToolchainProfile -Catalog $catalog -Profile $profile)
    Write-Host "Profile '$profile': $($packages.Count) packages."
}

Write-Host "Catalog '$($catalog.catalogId)' is valid."
