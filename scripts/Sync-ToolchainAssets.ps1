[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CatalogPath,
    [Parameter(Mandatory)][string]$Profile,
    [Parameter(Mandatory)][string]$AssetCacheRoot,
    [string]$GitHubCliPath = 'gh'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/ToolchainInstall.psm1') -Force
Sync-ToolchainAssets @PSBoundParameters
