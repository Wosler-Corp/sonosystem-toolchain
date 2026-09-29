[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CatalogPath,
    [Parameter(Mandatory)][ValidateSet('ci-windows', 'dev-windows')][string]$Profile,
    [Parameter(Mandatory)][string]$StatePath,
    [string]$InstallRoot = (Split-Path -Parent $StatePath)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\ToolchainInstall.psm1'
Import-Module $modulePath -Force

Test-InstalledToolchain -CatalogPath $CatalogPath -Profile $Profile -StatePath $StatePath -InstallRoot $InstallRoot
Write-Host "Installed toolchain matches profile '$Profile'."
