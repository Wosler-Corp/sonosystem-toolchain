[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CatalogPath,
    [Parameter(Mandatory)][ValidateSet('ci', 'developer')][string]$Context,
    [string]$RunnerImage,
    [string]$OutputPath,
    [switch]$MinGWOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/ToolchainPrerequisites.psm1') -Force
Test-ToolchainPrerequisites @PSBoundParameters
