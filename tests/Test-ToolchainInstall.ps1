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
        runnerPrerequisites = @([ordered]@{
            id = 'visual-studio-2022'
            platform = 'windows'
            context = 'runner'
            productSelection = '*'
            requiredComponents = @('Microsoft.Component.MSBuild', 'Microsoft.VisualStudio.Component.VC.CMake.Project', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.VC.Redist.14.Latest')
            generator = 'Visual Studio 17 2022'
            toolset = 'v143'
            versionFamily = '[17.0,18.0)'
            detection = [ordered]@{
                requiresComplete = $true
                requiresLaunchable = $true
            }
            bootstrap = [ordered]@{
                url = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'
                signerOrganization = 'Microsoft Corporation'
                arguments = @('--quiet', '--wait', '--norestart', '--nocache')
                successExitCodes = @(0, 1641, 3010)
                temporary = $true
            }
            supportedRunnerLabel = 'windows-latest-l'
        })
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
        [string]$StatePath = $Environment.StatePath,
        [string]$PnPUtilPath,
        [switch]$AllowDowngrade
    )

    $arguments = @{
        CatalogPath = $CatalogPath
        Profile = $Profile
        InstallRoot = $Environment.InstallRoot
        OfflineAssetRoot = $Environment.AssetRoot
        StatePath = $StatePath
    }
    if ($PnPUtilPath) { $arguments.PnPUtilPath = $PnPUtilPath }
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
        Assert-Equal -Actual $state.catalogId -Expected 'windows-test-1.0.0' -Message 'Catalog ID missing from state'
        Assert-Equal -Actual $state.profile -Expected 'ci-windows' -Message 'Profile missing from state'
        Assert-Equal -Actual $state.catalogSha256 -Expected (Get-PathHash $environment.CatalogPath) -Message 'Catalog SHA-256 missing from state'
        Assert-Equal -Actual @($state.packages.recipeVersion) -Expected @(1, 1) -Message 'Recipe versions missing from state'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'preserves a single command-version argument as one argument' {
    $environment = New-TestEnvironment
    try {
        $content = "@echo off`r`nif `"%~1`"==`"--probe`" (`r`n  echo probe version 1.2.3`r`n  exit /b 0`r`n)`r`nexit /b 9`r`n"
        $asset = New-ZipAsset -Environment $environment -AssetName 'probe-1.0.0.zip' -Content $content -RelativePath 'bin\probe.cmd'
        $package = New-PackageDefinition -Id 'probe' -Version '1.0.0' -Asset $asset -ProbePath 'bin\probe.cmd'
        $package.validation = @([ordered]@{
            type = 'command-version'
            path = 'bin\probe.cmd'
            arguments = @('--probe')
            version = '1.2.3'
        })
        Write-TestCatalog -Environment $environment -Packages @($package) -CiRoots @('probe') | Out-Null
        Install-ToolchainProfile -CatalogPath $environment.CatalogPath -Profile ci-windows `
            -InstallRoot $environment.InstallRoot -OfflineAssetRoot $environment.AssetRoot | Out-Null
        Assert-True -Condition (Test-Path -LiteralPath $environment.StatePath -PathType Leaf) -Message 'Successful single-argument probe did not write state'
    } finally { Remove-TestEnvironment $environment }
}

function New-FakePnPUtil {
    param(
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][ValidateSet('fail', 'succeed', 'fail-second')][string]$Behavior
    )

    $path = Join-Path $Environment.Root 'fake-pnputil.cmd'
    $logPath = Join-Path $Environment.Root 'pnputil-calls.txt'
    $firstCallPath = Join-Path $Environment.Root 'pnputil-first-call.txt'
    $lines = @('@echo off', "echo %*>>`"$logPath`"")
    switch ($Behavior) {
        'fail' { $lines += 'exit /b 42' }
        'succeed' { $lines += 'exit /b 0' }
        'fail-second' {
            $lines += "if exist `"$firstCallPath`" exit /b 42"
            $lines += "echo first>`"$firstCallPath`""
            $lines += 'exit /b 0'
        }
    }
    [IO.File]::WriteAllLines($path, $lines, [Text.ASCIIEncoding]::new())
    return [pscustomobject]@{ Path = $path; LogPath = $logPath }
}

function Write-DriverTestCatalog {
    param(
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][string[]]$DriverEntries
    )

    $runtimeAsset = New-ZipAsset -Environment $Environment -AssetName 'runtime-1.0.0.zip' -Content 'runtime'
    $packages = [Collections.Generic.List[object]]::new()
    $packages.Add((New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $runtimeAsset))
    $devRoots = [Collections.Generic.List[string]]::new()
    $devRoots.Add('runtime')
    for ($index = 0; $index -lt $DriverEntries.Count; $index++) {
        $id = "driver-$($index + 1)"
        $entry = $DriverEntries[$index]
        $asset = New-ZipAsset -Environment $Environment -AssetName "$id-1.0.0.zip" -Content "driver-$index" -RelativePath $entry
        $packages.Add((New-PackageDefinition -Id $id -Version '1.0.0' -Asset $asset -Kind 'driver' `
            -Target 'windows-driver-store' -Destination $id -ProbePath $entry))
        $devRoots.Add($id)
    }
    Write-TestCatalog -Environment $Environment -Packages $packages.ToArray() -CiRoots @('runtime') -DevRoots $devRoots.ToArray() | Out-Null
}

Invoke-Test 'changed recipe version invalidates the no-op path' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        $sentinel = Join-Path $baseline.Destination 'sentinel.keep'
        [IO.File]::WriteAllText($sentinel, 'old-recipe')
        $catalog = Get-Content -LiteralPath $environment.CatalogPath -Raw | ConvertFrom-Json -Depth 100
        $catalog.packages[0].install.recipeVersion = 2
        [IO.File]::WriteAllText($environment.CatalogPath, ($catalog | ConvertTo-Json -Depth 100))
        Assert-Throws -MessagePattern 'state|recipeVersion|catalog' -Action {
            & $validatorPath -CatalogPath $environment.CatalogPath -Profile 'ci-windows' -StatePath $environment.StatePath -InstallRoot $environment.InstallRoot
        }
        Invoke-Installer -Environment $environment
        Assert-True -Condition (-not (Test-Path -LiteralPath $sentinel)) -Message 'Changed recipe was skipped.'
        $state = Get-Content -LiteralPath $environment.StatePath -Raw | ConvertFrom-Json -Depth 100
        Assert-Equal -Actual $state.packages[0].recipeVersion -Expected 2 -Message 'Updated recipe version not recorded'
        Assert-Equal -Actual $state.catalogSha256 -Expected (Get-PathHash $environment.CatalogPath) -Message 'Updated catalog hash not recorded'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'legacy state without a recipe version is reinstalled' {
    $environment = New-TestEnvironment
    try {
        $baseline = Install-Baseline -Environment $environment
        $sentinel = Join-Path $baseline.Destination 'sentinel.keep'
        [IO.File]::WriteAllText($sentinel, 'old-recipe')
        $state = Get-Content -LiteralPath $environment.StatePath -Raw | ConvertFrom-Json -Depth 100
        $state.packages[0].PSObject.Properties.Remove('recipeVersion')
        [IO.File]::WriteAllText($environment.StatePath, ($state | ConvertTo-Json -Depth 100))
        Invoke-Installer -Environment $environment
        Assert-True -Condition (-not (Test-Path -LiteralPath $sentinel)) -Message 'Legacy state was incorrectly skipped.'
        $updated = Get-Content -LiteralPath $environment.StatePath -Raw | ConvertFrom-Json -Depth 100
        Assert-Equal -Actual $updated.packages[0].recipeVersion -Expected 1 -Message 'Recipe version was not restored.'
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

Invoke-Test 'rejects driver packages in the CI profile' {
    $environment = New-TestEnvironment
    try {
        $asset = New-ZipAsset -Environment $environment -AssetName 'cp210x-driver-11.4.0.zip' -Content 'driver'
        $package = New-PackageDefinition -Id 'cp210x-driver' -Version '11.4.0' -Asset $asset `
            -Kind 'driver' -Target 'windows-driver-store' -Destination 'cp210x-driver'
        Write-TestCatalog -Environment $environment -Packages @($package) -CiRoots @('cp210x-driver') -DevRoots @('cp210x-driver') | Out-Null
        Assert-Throws -MessagePattern 'ci-windows.*driver|driver.*ci-windows' -Action { Invoke-Installer -Environment $environment }
        Assert-True -Condition (-not (Test-Path -LiteralPath $environment.StatePath)) -Message 'Invalid CI profile wrote state.'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'failed pnputil leaves no driver state and warns about cleanup and reboot' {
    $environment = New-TestEnvironment
    $originalWindir = $env:WINDIR
    try {
        $baseline = Install-Baseline -Environment $environment
        $stateHash = Get-PathHash $environment.StatePath
        $driverAsset = New-ZipAsset -Environment $environment -AssetName 'cp210x-driver-11.4.0.zip' -Content 'driver' -RelativePath 'silabser.inf'
        $driver = New-PackageDefinition -Id 'cp210x-driver' -Version '11.4.0' -Asset $driverAsset -Kind 'driver' -Target 'windows-driver-store' -Destination 'cp210x-driver' -ProbePath 'silabser.inf'
        $runtime = New-PackageDefinition -Id 'runtime' -Version '1.0.0' -Asset $baseline.Asset
        Write-TestCatalog -Environment $environment -Packages @($runtime, $driver) -CiRoots @('runtime') -DevRoots @('runtime', 'cp210x-driver') | Out-Null
        $env:WINDIR = Join-Path $environment.Root 'fake-windows'
        Assert-Throws -MessagePattern 'Driver Store.*cleanup.*reboot' -Action { Invoke-Installer -Environment $environment -Profile 'dev-windows' }
        Assert-Equal -Actual (Get-PathHash $environment.StatePath) -Expected $stateHash -Message 'Failed driver installation wrote state.'
    } finally {
        $env:WINDIR = $originalWindir
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'preflights every driver INF set before calling pnputil' {
    $environment = New-TestEnvironment
    $originalWindir = $env:WINDIR
    try {
        Write-DriverTestCatalog -Environment $environment -DriverEntries @('first.inf', 'payload.txt')
        $env:WINDIR = Join-Path $environment.Root 'missing-pnputil'
        Assert-Throws -MessagePattern "driver-2.*no INF" -Action {
            Invoke-Installer -Environment $environment -Profile 'dev-windows'
        }
        Assert-True -Condition (-not (Test-Path -LiteralPath $environment.StatePath)) `
            -Message 'Missing second INF wrote successful driver state.'
    } finally {
        $env:WINDIR = $originalWindir
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'native pnputil nonzero exit warns and writes no successful state' {
    $environment = New-TestEnvironment
    try {
        Write-DriverTestCatalog -Environment $environment -DriverEntries @('first.inf')
        $fake = New-FakePnPUtil -Environment $environment -Behavior 'fail'
        Assert-Throws -MessagePattern '42.*Driver Store.*cleanup.*reboot' -Action {
            Invoke-Installer -Environment $environment -Profile 'dev-windows' -PnPUtilPath $fake.Path
        }
        Assert-Equal -Actual @(Get-Content -LiteralPath $fake.LogPath).Count -Expected 1 -Message 'Expected one native pnputil invocation'
        Assert-True -Condition (-not (Test-Path -LiteralPath $environment.StatePath)) -Message 'Failed pnputil wrote successful state.'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'second pnputil failure warns after the first driver succeeds' {
    $environment = New-TestEnvironment
    try {
        Write-DriverTestCatalog -Environment $environment -DriverEntries @('first.inf', 'second.inf')
        $fake = New-FakePnPUtil -Environment $environment -Behavior 'fail-second'
        Assert-Throws -MessagePattern '42.*Driver Store.*cleanup.*reboot' -Action {
            Invoke-Installer -Environment $environment -Profile 'dev-windows' -PnPUtilPath $fake.Path
        }
        Assert-Equal -Actual @(Get-Content -LiteralPath $fake.LogPath).Count -Expected 2 -Message 'Expected two native pnputil invocations'
        Assert-True -Condition (-not (Test-Path -LiteralPath $environment.StatePath)) -Message 'Partial driver install wrote successful state.'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Invoke-Test 'state-write failure after driver execution warns about partial Driver Store changes' {
    $environment = New-TestEnvironment
    try {
        Write-DriverTestCatalog -Environment $environment -DriverEntries @('first.inf')
        $fake = New-FakePnPUtil -Environment $environment -Behavior 'succeed'
        $blockingFile = Join-Path $environment.Root 'state-parent-is-a-file'
        [IO.File]::WriteAllText($blockingFile, 'block state write')
        $statePath = Join-Path $blockingFile 'installed-toolchain.json'
        Assert-Throws -MessagePattern 'Driver Store.*cleanup.*reboot' -Action {
            Invoke-Installer -Environment $environment -Profile 'dev-windows' -PnPUtilPath $fake.Path -StatePath $statePath
        }
        Assert-Equal -Actual @(Get-Content -LiteralPath $fake.LogPath).Count -Expected 1 -Message 'Driver execution did not precede state-write failure'
        Assert-True -Condition (-not (Test-Path -LiteralPath $statePath)) -Message 'Failed state write left successful state.'
    } finally {
        Remove-TestEnvironment $environment
    }
}

Write-Host "Installer tests: $script:passed passed, $script:failed failed."
if ($script:failed -ne 0) {
    exit 1
}
