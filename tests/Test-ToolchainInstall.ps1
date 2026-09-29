[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$installerModulePath = Join-Path $repoRoot 'src\ToolchainInstall.psm1'
$installerPath = Join-Path $repoRoot 'scripts\Install-ToolchainProfile.ps1'
$validatorPath = Join-Path $repoRoot 'scripts\Test-InstalledToolchain.ps1'

foreach ($requiredPath in @($installerModulePath, $installerPath, $validatorPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Toolchain installer component not found: $requiredPath"
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:passed = 0
$script:failed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    $actualJson = ConvertTo-Json -InputObject $Actual -Depth 100 -Compress
    $expectedJson = ConvertTo-Json -InputObject $Expected -Depth 100 -Compress
    if ($actualJson -cne $expectedJson) {
        throw "$Message. Expected $expectedJson, found $actualJson."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$MessagePattern
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "Expected error matching '$MessagePattern', found '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error matching '$MessagePattern', but no error was thrown."
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    try {
        & $Body
        $script:passed++
        Write-Host "PASS: $Name"
    } catch {
        $script:failed++
        Write-Error "FAIL: ${Name}: $($_.Exception.Message)" -ErrorAction Continue
    }
}

function New-TestEnvironment {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $root = Join-Path $base "toolchain-install-test-$([Guid]::NewGuid().ToString('N'))"
    $assetRoot = Join-Path $root 'assets'
    $installRoot = Join-Path $root 'installed'
    [IO.Directory]::CreateDirectory($assetRoot) | Out-Null
    [IO.Directory]::CreateDirectory($installRoot) | Out-Null
    return [pscustomobject]@{
        Root = $root
        AssetRoot = $assetRoot
        InstallRoot = $installRoot
        CatalogPath = Join-Path $root 'catalog.json'
        StatePath = Join-Path $installRoot 'installed-toolchain.json'
    }
}

function Remove-TestEnvironment {
    param([Parameter(Mandatory)]$Environment)
    if (Test-Path -LiteralPath $Environment.Root) {
        Remove-Item -LiteralPath $Environment.Root -Recurse -Force
    }
}

function New-ZipAsset {
    param(
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][string]$AssetName,
        [Parameter(Mandatory)][string]$Content,
        [string]$RelativePath = 'bin\tool.exe'
    )

    $sourceRoot = Join-Path $Environment.Root "source-$([Guid]::NewGuid().ToString('N'))"
    $sourcePath = Join-Path $sourceRoot $RelativePath
    [IO.Directory]::CreateDirectory((Split-Path -Parent $sourcePath)) | Out-Null
    [IO.File]::WriteAllText($sourcePath, $Content, [Text.UTF8Encoding]::new($false))
    $assetPath = Join-Path $Environment.AssetRoot $AssetName
    [IO.Compression.ZipFile]::CreateFromDirectory($sourceRoot, $assetPath)
    Remove-Item -LiteralPath $sourceRoot -Recurse -Force
    return [pscustomobject]@{
        Name = $AssetName
        Path = $assetPath
        Sha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        SizeBytes = (Get-Item -LiteralPath $assetPath).Length
        ExpandedSizeBytes = ([Text.UTF8Encoding]::new($false)).GetByteCount($Content)
    }
}

function New-SpecialZipAsset {
    param(
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][string]$AssetName,
        [Parameter(Mandatory)][string]$EntryName,
        [switch]$ReparsePoint
    )

    $assetPath = Join-Path $Environment.AssetRoot $AssetName
    $stream = [IO.File]::Open($assetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $entry = $archive.CreateEntry($EntryName)
            if ($ReparsePoint) {
                $entry.ExternalAttributes = [int][IO.FileAttributes]::ReparsePoint
            }
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try {
                $writer.Write('unsafe')
            } finally {
                $writer.Dispose()
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    return [pscustomobject]@{
        Name = $AssetName
        Path = $assetPath
        Sha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        SizeBytes = (Get-Item -LiteralPath $assetPath).Length
        ExpandedSizeBytes = 6
    }
}

function New-PackageDefinition {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)]$Asset,
        [string[]]$Dependencies = @(),
        [string]$Destination = $Id,
        [string]$Kind = 'zip',
        [string]$Target = 'toolchain-root',
        [long]$ExpandedLimit = 0,
        [string]$ProbePath = 'bin\tool.exe'
    )

    if ($ExpandedLimit -eq 0) {
        $ExpandedLimit = [Math]::Max(1, [long]$Asset.ExpandedSizeBytes)
    }
    return [ordered]@{
        id = $Id
        version = $Version
        release = [ordered]@{
            repository = 'Wosler-Corp/sonosystem-toolchain'
            tag = "$Id-$Version"
            asset = $Asset.Name
            sha256 = $Asset.Sha256
            sizeBytes = [long]$Asset.SizeBytes
            attestation = 'github-immutable-release'
        }
        upstream = [ordered]@{
            url = "https://vendor.invalid/$($Asset.Name)"
            version = $Version
            retrievedAt = '2026-09-29T00:00:00Z'
        }
        licenses = @("licenses/$Id/$Version/LICENSE.txt")
        dependencies = @($Dependencies)
        install = [ordered]@{
            recipeVersion = 1
            kind = $Kind
            target = $Target
            destination = $Destination
            expandedSizeBytes = $ExpandedLimit
        }
        validation = @(
            [ordered]@{
                type = 'file-exists'
                path = $ProbePath
            }
        )
    }
}

function Write-TestCatalog {
    param(
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][object[]]$Packages,
        [string[]]$CiRoots = @('runtime'),
        [string[]]$DevRoots = $CiRoots,
        [string]$Path = $Environment.CatalogPath
    )

    $catalog = [ordered]@{
        schemaVersion = 1
        catalogId = 'windows-test-1.0.0'
        platform = 'windows'
        architecture = 'x86_64'
        packages = @($Packages)
        profiles = [ordered]@{
            'ci-windows' = @($CiRoots)
            'dev-windows' = @($DevRoots)
        }
    }
    $json = $catalog | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
    return $Path
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory)]$Environment,
        [string]$CatalogPath = $Environment.CatalogPath,
        [string]$Profile = 'ci-windows',
        [ValidateSet('Image', 'Developer')][string]$Mode = 'Image',
        [switch]$AllowDowngrade
    )

    $arguments = @{
        CatalogPath = $CatalogPath
        Profile = $Profile
        InstallRoot = $Environment.InstallRoot
        OfflineAssetRoot = $Environment.AssetRoot
        StatePath = $Environment.StatePath
        Mode = $Mode
    }
    if ($AllowDowngrade) {
        $arguments.AllowDowngrade = $true
    }
    & $installerPath @arguments | Out-Null
}

function Get-PathHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return '<missing>'
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Install-Baseline {
    param([Parameter(Mandatory)]$Environment)

    $asset = New-ZipAsset -Environment $Environment -AssetName 'runtime-1.0.0.zip' -Content 'version-one'
    $package = New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $asset
    Write-TestCatalog -Environment $Environment -Packages @($package) | Out-Null
    Invoke-Installer -Environment $Environment
    return [pscustomobject]@{
        Asset = $asset
        Destination = Join-Path $Environment.InstallRoot 'runtime'
        Payload = Join-Path $Environment.InstallRoot 'runtime\bin\tool.exe'
    }
}

function Assert-BaselinePreserved {
    param(
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)]$Baseline,
        [Parameter(Mandatory)][string]$PayloadHash,
        [Parameter(Mandatory)][string]$StateHash
    )

    Assert-Equal -Actual (Get-PathHash $Baseline.Payload) -Expected $PayloadHash `
        -Message 'Installed payload changed after a rejected operation'
    Assert-Equal -Actual (Get-PathHash $Environment.StatePath) -Expected $StateHash `
        -Message 'Installed state changed after a rejected operation'
}

Invoke-Test 'rejects a wrong archive length without changing installed state' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        $payloadHash = Get-PathHash $baseline.Payload
        $stateHash = Get-PathHash $environment.StatePath
        $catalog = Get-Content -LiteralPath $environment.CatalogPath -Raw | ConvertFrom-Json -Depth 100
        $catalog.packages[0].release.sizeBytes++
        [IO.File]::WriteAllText($environment.CatalogPath, ($catalog | ConvertTo-Json -Depth 100))
        Assert-Throws -MessagePattern 'size' -Action { Invoke-Installer -Environment $environment }
        Assert-BaselinePreserved -Environment $environment -Baseline $baseline -PayloadHash $payloadHash -StateHash $stateHash
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'rejects a wrong archive hash without changing installed state' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        $payloadHash = Get-PathHash $baseline.Payload
        $stateHash = Get-PathHash $environment.StatePath
        $catalog = Get-Content -LiteralPath $environment.CatalogPath -Raw | ConvertFrom-Json -Depth 100
        $catalog.packages[0].release.sha256 = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
        [IO.File]::WriteAllText($environment.CatalogPath, ($catalog | ConvertTo-Json -Depth 100))
        Assert-Throws -MessagePattern 'SHA-256|sha256' -Action { Invoke-Installer -Environment $environment }
        Assert-BaselinePreserved -Environment $environment -Baseline $baseline -PayloadHash $payloadHash -StateHash $stateHash
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'rejects an offline asset not listed in the catalog' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        $payloadHash = Get-PathHash $baseline.Payload
        $stateHash = Get-PathHash $environment.StatePath
        [IO.File]::WriteAllText((Join-Path $environment.AssetRoot 'unlisted.zip'), 'not-listed')
        Assert-Throws -MessagePattern 'unlisted|not listed|unexpected' -Action { Invoke-Installer -Environment $environment }
        Assert-BaselinePreserved -Environment $environment -Baseline $baseline -PayloadHash $payloadHash -StateHash $stateHash
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'rejects a non-Wosler asset repository' {
    $environment = New-TestEnvironment
    try {
        $asset = New-ZipAsset -Environment $environment -AssetName 'runtime-1.0.0.zip' -Content 'version-one'
        $package = New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $asset
        $package.release.repository = 'vendor/runtime'
        Write-TestCatalog -Environment $environment -Packages @($package) | Out-Null
        Assert-Throws -MessagePattern 'repository' -Action { Invoke-Installer -Environment $environment }
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $environment.InstallRoot 'runtime'))) `
            -Message 'Non-Wosler package created an installation directory.'
    } finally {
        Remove-TestEnvironment $environment
    }
}

foreach ($unsafeEntry in @('..\escaped.txt', 'C:\absolute.txt')) {
    Invoke-Test "rejects unsafe ZIP entry $unsafeEntry" {
        $environment = New-TestEnvironment
        try {
            $asset = New-SpecialZipAsset -Environment $environment -AssetName 'runtime-1.0.0.zip' -EntryName $unsafeEntry
            $package = New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $asset -ProbePath 'escaped.txt'
            Write-TestCatalog -Environment $environment -Packages @($package) | Out-Null
            Assert-Throws -MessagePattern 'archive|entry|path|traversal|absolute' -Action { Invoke-Installer -Environment $environment }
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $environment.Root 'escaped.txt'))) `
                -Message 'Unsafe ZIP entry wrote outside staging.'
        } finally {
            Remove-TestEnvironment $environment
        }
    }
}

Invoke-Test 'rejects a reparse-point ZIP entry' {
    $environment = New-TestEnvironment
    try {
        $asset = New-SpecialZipAsset -Environment $environment -AssetName 'runtime-1.0.0.zip' -EntryName 'link' -ReparsePoint
        $package = New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $asset -ProbePath 'link'
        Write-TestCatalog -Environment $environment -Packages @($package) | Out-Null
        Assert-Throws -MessagePattern 'reparse|link|archive entry' -Action { Invoke-Installer -Environment $environment }
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'rejects an archive whose expanded size exceeds the catalog limit' {
    $environment = New-TestEnvironment
    try {
        $asset = New-ZipAsset -Environment $environment -AssetName 'runtime-1.0.0.zip' -Content 'content-larger-than-limit'
        $package = New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $asset -ExpandedLimit 1
        Write-TestCatalog -Environment $environment -Packages @($package) | Out-Null
        Assert-Throws -MessagePattern 'expanded.*size|size.*limit' -Action { Invoke-Installer -Environment $environment }
    } finally {
        Remove-TestEnvironment $environment
    }
}

foreach ($invalidInstall in @(
    @{ Name = 'kind'; Value = 'script' },
    @{ Name = 'target'; Value = 'C:\arbitrary' }
)) {
    Invoke-Test "rejects unsupported install $($invalidInstall.Name)" {
        $environment = New-TestEnvironment
        try {
            $asset = New-ZipAsset -Environment $environment -AssetName 'runtime-1.0.0.zip' -Content 'version-one'
            $package = New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $asset
            $package.install[$invalidInstall.Name] = $invalidInstall.Value
            Write-TestCatalog -Environment $environment -Packages @($package) | Out-Null
            Assert-Throws -MessagePattern $invalidInstall.Name -Action { Invoke-Installer -Environment $environment }
        } finally {
            Remove-TestEnvironment $environment
        }
    }
}

Invoke-Test 'rolls back payload and state when an installed validation probe fails' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        $payloadHash = Get-PathHash $baseline.Payload
        $stateHash = Get-PathHash $environment.StatePath
        [IO.File]::Delete($baseline.Asset.Path)
        $upgradeAsset = New-ZipAsset -Environment $environment -AssetName 'runtime-1.1.0.zip' -Content 'version-two'
        $upgradePackage = New-PackageDefinition -Id 'runtime' -Version '1.1.0' -Asset $upgradeAsset -ProbePath 'bin\missing.exe'
        Write-TestCatalog -Environment $environment -Packages @($upgradePackage) | Out-Null
        Assert-Throws -MessagePattern 'validation|missing' -Action { Invoke-Installer -Environment $environment }
        Assert-BaselinePreserved -Environment $environment -Baseline $baseline -PayloadHash $payloadHash -StateHash $stateHash
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'records packages in deterministic dependency order' {
    $environment = New-TestEnvironment
    try {
        $baseAsset = New-ZipAsset -Environment $environment -AssetName 'base-1.0.0.zip' -Content 'base'
        $appAsset = New-ZipAsset -Environment $environment -AssetName 'app-1.0.0.zip' -Content 'app'
        $basePackage = New-PackageDefinition -Id 'base' -Version '1.0.0' -Asset $baseAsset -Destination 'base'
        $appPackage = New-PackageDefinition -Id 'app' -Version '1.0.0' -Asset $appAsset -Dependencies @('base') -Destination 'app'
        Write-TestCatalog -Environment $environment -Packages @($appPackage, $basePackage) -CiRoots @('app') -DevRoots @('app') | Out-Null
        Invoke-Installer -Environment $environment
        $state = Get-Content -LiteralPath $environment.StatePath -Raw | ConvertFrom-Json -Depth 100
        Assert-Equal -Actual @($state.packages.id) -Expected @('base', 'app') `
            -Message 'Installed-state dependency order is incorrect'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'leaves a matching installation untouched on rerun' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        $sentinel = Join-Path $baseline.Destination 'sentinel.keep'
        [IO.File]::WriteAllText($sentinel, 'preserve-me')
        Invoke-Installer -Environment $environment
        Assert-True -Condition (Test-Path -LiteralPath $sentinel -PathType Leaf) `
            -Message 'Matching package was reinstalled instead of skipped.'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'repairs a matching-version package when a validation file is missing' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        [IO.File]::Delete($baseline.Payload)
        Invoke-Installer -Environment $environment
        Assert-Equal -Actual ([IO.File]::ReadAllText($baseline.Payload)) -Expected 'version-one' `
            -Message 'Missing installed payload was not repaired'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'upgrades an installed package explicitly' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        [IO.File]::Delete($baseline.Asset.Path)
        $upgradeAsset = New-ZipAsset -Environment $environment -AssetName 'runtime-1.1.0.zip' -Content 'version-two'
        $upgradePackage = New-PackageDefinition -Id 'runtime' -Version '1.1.0' -Asset $upgradeAsset
        Write-TestCatalog -Environment $environment -Packages @($upgradePackage) | Out-Null
        Invoke-Installer -Environment $environment
        Assert-Equal -Actual ([IO.File]::ReadAllText($baseline.Payload)) -Expected 'version-two' `
            -Message 'Package payload was not upgraded'
        $state = Get-Content -LiteralPath $environment.StatePath -Raw | ConvertFrom-Json -Depth 100
        Assert-Equal -Actual $state.packages[0].version -Expected '1.1.0' `
            -Message 'Installed state did not record the upgraded version'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'refuses downgrade unless AllowDowngrade is supplied' {
    $environment = New-TestEnvironment
    try {
        $newAsset = New-ZipAsset -Environment $environment -AssetName 'runtime-1.1.0.zip' -Content 'version-two'
        $newPackage = New-PackageDefinition -Id 'runtime' -Version '1.1.0' -Asset $newAsset
        Write-TestCatalog -Environment $environment -Packages @($newPackage) | Out-Null
        Invoke-Installer -Environment $environment
        [IO.File]::Delete($newAsset.Path)

        $oldAsset = New-ZipAsset -Environment $environment -AssetName 'runtime-1.0.0.zip' -Content 'version-one'
        $oldPackage = New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $oldAsset
        Write-TestCatalog -Environment $environment -Packages @($oldPackage) | Out-Null
        Assert-Throws -MessagePattern 'downgrade' -Action { Invoke-Installer -Environment $environment }
        Assert-Equal -Actual ([IO.File]::ReadAllText((Join-Path $environment.InstallRoot 'runtime\bin\tool.exe'))) `
            -Expected 'version-two' -Message 'Rejected downgrade changed the installed payload'

        Invoke-Installer -Environment $environment -AllowDowngrade
        Assert-Equal -Actual ([IO.File]::ReadAllText((Join-Path $environment.InstallRoot 'runtime\bin\tool.exe'))) `
            -Expected 'version-one' -Message 'Allowed downgrade did not install the selected package'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'rejects driver packages in image mode' {
    $environment = New-TestEnvironment
    try {
        $asset = New-ZipAsset -Environment $environment -AssetName 'cp210x-driver-11.4.0.zip' -Content 'driver'
        $package = New-PackageDefinition -Id 'cp210x-driver' -Version '11.4.0' -Asset $asset `
            -Kind 'driver' -Target 'windows-driver-store' -Destination 'cp210x-driver'
        Write-TestCatalog -Environment $environment -Packages @($package) -CiRoots @('cp210x-driver') -DevRoots @('cp210x-driver') | Out-Null
        Assert-Throws -MessagePattern 'driver.*image|image.*driver' -Action { Invoke-Installer -Environment $environment }
    } finally {
        Remove-TestEnvironment $environment
    }
}

Write-Host "Installer tests: $script:passed passed, $script:failed failed."
if ($script:failed -ne 0) {
    exit 1
}
