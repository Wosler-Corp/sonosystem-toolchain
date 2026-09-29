[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CatalogPath,
    [Parameter(Mandatory)][ValidateSet('ci-windows', 'dev-windows')][string]$Profile,
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$OfflineAssetRoot,
    [string]$StatePath,
    [string]$GitHubCliPath = 'gh',
    [switch]$AllowDowngrade
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\ToolchainInstall.psm1'
Import-Module $modulePath -Force

$arguments = @{
    CatalogPath = $CatalogPath
    Profile = $Profile
    InstallRoot = $InstallRoot
    GitHubCliPath = $GitHubCliPath
}
if ($OfflineAssetRoot) { $arguments.OfflineAssetRoot = $OfflineAssetRoot }
if ($StatePath) { $arguments.StatePath = $StatePath }
if ($AllowDowngrade) { $arguments.AllowDowngrade = $true }

$state = Install-ToolchainProfile @arguments
Write-Host "Installed catalog '$($state.catalogId)' profile '$($state.profile)' with $(@($state.packages).Count) packages."
