[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src\ToolchainCatalog.psm1'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\catalog-valid.json'
$schemaPath = Join-Path $repoRoot 'catalog\schema\toolchain-catalog-v1.schema.json'

if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "ToolchainCatalog.psm1 not found: $modulePath"
}

Import-Module $modulePath -Force

$script:passed = 0
$script:failed = 0

function Copy-CatalogFixture {
    $json = Get-Content -LiteralPath $fixturePath -Raw
    return $json | ConvertFrom-Json -Depth 100
}

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

Invoke-Test 'accepts the valid catalog fixture' {
    $catalog = Copy-CatalogFixture
    Test-ToolchainCatalog -Catalog $catalog
}

Invoke-Test 'valid fixture satisfies the published JSON schema' {
    $fixtureJson = Get-Content -LiteralPath $fixturePath -Raw
    if (-not ($fixtureJson | Test-Json -SchemaFile $schemaPath)) {
        throw 'Valid catalog fixture did not satisfy toolchain-catalog-v1.schema.json.'
    }
}

Invoke-Test 'Visual Studio is an exact runner prerequisite, not a package' {
    $catalog = Copy-CatalogFixture
    Test-ToolchainCatalog -Catalog $catalog
    Assert-Equal -Actual @($catalog.runnerPrerequisites).Count -Expected 1 -Message 'Expected one runner prerequisite'
    $item = $catalog.runnerPrerequisites[0]
    Assert-Equal -Actual $item.id -Expected 'visual-studio-2022' -Message 'Prerequisite ID differs'
    Assert-Equal -Actual $item.productId -Expected 'Microsoft.VisualStudio.Product.Enterprise' -Message 'Product ID differs'
    Assert-Equal -Actual @($item.requiredComponents) -Expected @(
        'Microsoft.Component.MSBuild',
        'Microsoft.VisualStudio.Component.VC.CMake.Project',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        'Microsoft.VisualStudio.Component.VC.Redist.14.Latest'
    ) -Message 'Required components differ'
    Assert-Equal -Actual "$($item.toolset):$($item.versionFamily)" -Expected 'v143:[17.0,18.0)' -Message 'Toolset pin differs'
    Assert-Equal -Actual @($item.versionProbes.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -Expected @(
        'installationVersion=17.14.0.0', 'vcToolsVersion=14.43.34808',
        'compilerVersion=19.43.34810', 'msbuildVersion=17.14.0.0'
    ) -Message 'Exact version probes differ'
    Assert-Equal -Actual $item.supportedRunnerLabel -Expected 'windows-latest-l' -Message 'Runner label differs'
    foreach ($field in @('release', 'upstream', 'install', 'assetUrl')) {
        if ($item.PSObject.Properties[$field]) { throw "Prerequisite contains $field metadata." }
    }
    if ($item.id -cin @($catalog.packages.id)) { throw 'Prerequisite is packaged.' }
    foreach ($profile in @('ci-windows', 'dev-windows')) {
        if ($item.id -cin @((Resolve-ToolchainProfile -Catalog $catalog -Profile $profile).id)) { throw "Prerequisite is in $profile." }
    }
}

$invalidPrerequisites = @(
    @{ Name = 'duplicate prerequisite ID'; Error = 'duplicate.*prerequisite'; Mutate = { param($c) $c.runnerPrerequisites = @($c.runnerPrerequisites) + @(($c.runnerPrerequisites[0] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)) } },
    @{ Name = 'prerequisite asset URL'; Error = 'assetUrl|unsupported'; Mutate = { param($c) $c.runnerPrerequisites[0] | Add-Member -NotePropertyName assetUrl -NotePropertyValue 'https://vendor.invalid/vs.exe' } },
    @{ Name = 'missing prerequisite component'; Error = 'component'; Mutate = { param($c) $c.runnerPrerequisites[0].requiredComponents = @() } },
    @{ Name = 'floating prerequisite version'; Error = 'version'; Mutate = { param($c) $c.runnerPrerequisites[0].versionProbes.compilerVersion = 'latest' } },
    @{ Name = 'unsupported runner label'; Error = 'label'; Mutate = { param($c) $c.runnerPrerequisites[0].supportedRunnerLabel = 'custom-image' } },
    @{ Name = 'prerequisite ID collides with package'; Error = 'prerequisite|duplicate'; Mutate = { param($c) $c.runnerPrerequisites[0].id = 'runtime' } },
    @{ Name = 'CI profile contains a driver'; Error = 'ci-windows.*driver|driver.*ci-windows'; Mutate = { param($c) $c.profiles.'ci-windows' = @('compiler', 'cp210x-driver') } },
    @{ Name = 'MSI install kind'; Error = 'kind'; Mutate = { param($c) $c.packages[0].install.kind = 'msi' } },
    @{ Name = 'EXE install kind'; Error = 'kind'; Mutate = { param($c) $c.packages[0].install.kind = 'exe' } }
)
foreach ($case in $invalidPrerequisites) {
    Invoke-Test "rejects $($case.Name)" {
        $catalog = Copy-CatalogFixture
        & $case.Mutate $catalog
        Assert-Throws -MessagePattern $case.Error -Action { Test-ToolchainCatalog -Catalog $catalog }
    }
}

$invalidCases = @(
    @{
        Name = 'rejects an unsupported schema version'
        Error = 'schemaVersion'
        Mutate = { param($catalog) $catalog.schemaVersion = 2 }
    },
    @{
        Name = 'rejects a duplicate package ID'
        Error = 'duplicate.*runtime'
        Mutate = {
            param($catalog)
            $duplicate = ($catalog.packages[0] | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100
            $catalog.packages = @($catalog.packages) + $duplicate
        }
    },
    @{
        Name = 'rejects a missing dependency'
        Error = 'missing.*dependency'
        Mutate = { param($catalog) $catalog.packages[1].dependencies = @('not-present') }
    },
    @{
        Name = 'rejects a dependency cycle'
        Error = 'cycle'
        Mutate = { param($catalog) $catalog.packages[0].dependencies = @('compiler') }
    },
    @{
        Name = 'rejects an unpinned version'
        Error = 'version'
        Mutate = { param($catalog) $catalog.packages[0].version = 'latest' }
    },
    @{
        Name = 'rejects a non-Wosler asset repository'
        Error = 'repository'
        Mutate = { param($catalog) $catalog.packages[0].release.repository = 'vendor/runtime' }
    },
    @{
        Name = 'rejects an invalid SHA-256 digest'
        Error = 'sha256'
        Mutate = { param($catalog) $catalog.packages[0].release.sha256 = '1234' }
    },
    @{
        Name = 'rejects an unsafe install target'
        Error = 'target'
        Mutate = { param($catalog) $catalog.packages[0].install.target = 'C:\arbitrary' }
    },
    @{
        Name = 'rejects missing license metadata'
        Error = 'license'
        Mutate = { param($catalog) $catalog.packages[0].licenses = @() }
    },
    @{
        Name = 'rejects missing provenance metadata'
        Error = 'upstream'
        Mutate = { param($catalog) $catalog.packages[0].PSObject.Properties.Remove('upstream') }
    }
)

foreach ($case in $invalidCases) {
    Invoke-Test $case.Name {
        $catalog = Copy-CatalogFixture
        & $case.Mutate $catalog
        Assert-Throws -MessagePattern $case.Error -Action {
            Test-ToolchainCatalog -Catalog $catalog
        }
    }
}

Invoke-Test 'resolves CI dependencies once and before their consumer' {
    $catalog = Copy-CatalogFixture
    $resolved = @(Resolve-ToolchainProfile -Catalog $catalog -Profile 'ci-windows')
    Assert-Equal -Actual @($resolved.id) -Expected @('runtime', 'compiler') `
        -Message 'ci-windows dependency order is incorrect'
}

Invoke-Test 'resolves the developer profile as the CI closure plus CP210x' {
    $catalog = Copy-CatalogFixture
    $resolved = @(Resolve-ToolchainProfile -Catalog $catalog -Profile 'dev-windows')
    Assert-Equal -Actual @($resolved.id) -Expected @('runtime', 'compiler', 'cp210x-driver') `
        -Message 'dev-windows profile closure is incorrect'
}

$productionCatalogPath = Join-Path $repoRoot 'catalog\windows\2026.09.0.json'
$definitionRoot = Join-Path $repoRoot 'packages\windows'
$expectedDefinitionIds = @(
    'host-tools',
    'msys2-sonosystem',
    'vcpkg-sonosystem',
    'boost-mingw',
    'boost-msvc',
    'libdatachannel',
    'cmake-sources',
    'cp210x'
)

function Read-ProductionCatalog {
    if (-not (Test-Path -LiteralPath $productionCatalogPath -PathType Leaf)) {
        throw "Production catalog not found: $productionCatalogPath"
    }
    return Read-ToolchainCatalog -Path $productionCatalogPath
}

function Read-PackageDefinition {
    param([Parameter(Mandatory)][string]$Id)
    $path = Join-Path $definitionRoot "$Id.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Package definition not found: $path" }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
}

Invoke-Test 'production catalog defines the exact Windows package inventory' {
    $catalog = Read-ProductionCatalog
    Test-ToolchainCatalog -Catalog $catalog
    Assert-Equal -Actual $catalog.catalogId -Expected 'windows-2026.09.0' -Message 'Production catalog ID is incorrect'
    Assert-Equal -Actual @($catalog.packages.id) -Expected $expectedDefinitionIds -Message 'Production package inventory is incorrect'

    $ciIds = @((Resolve-ToolchainProfile -Catalog $catalog -Profile 'ci-windows').id)
    $devIds = @((Resolve-ToolchainProfile -Catalog $catalog -Profile 'dev-windows').id)
    Assert-Equal -Actual $ciIds -Expected @($expectedDefinitionIds | Where-Object { $_ -cne 'cp210x' }) -Message 'CI profile inventory is incorrect'
    Assert-Equal -Actual $devIds -Expected $expectedDefinitionIds -Message 'Developer profile must extend CI with CP210x'
    if ('cp210x' -cin $ciIds) { throw 'CP210x must not belong to ci-windows.' }
    if ('cp210x' -cnotin $devIds) { throw 'CP210x must belong to dev-windows.' }
    if (@($catalog.packages.id | Where-Object { $_ -match '(?i)inno' }).Count -ne 0) { throw 'Inno Setup is outside the SW_SS-655 package profiles.' }
}

Invoke-Test 'host-tools pins CMake 3.30.6 and 7-Zip 19.00' {
    $definition = Read-PackageDefinition -Id 'host-tools'
    Assert-Equal -Actual @($definition.contents | ForEach-Object { "$($_.id)=$($_.version)" }) `
        -Expected @('cmake=3.30.6', '7zip=19.00') -Message 'Host-tool pins are incorrect'
}

Invoke-Test 'MSYS2 package definition freezes the SonoBot dependency list' {
    $definition = Read-PackageDefinition -Id 'msys2-sonosystem'
    Assert-Equal -Actual $definition.base.version -Expected '20240507' -Message 'MSYS2 base version is incorrect'
    Assert-Equal -Actual @($definition.packages) -Expected @(
        'mingw-w64-x86_64-crt-git',
        'mingw-w64-x86_64-headers-git',
        'mingw-w64-x86_64-toolchain',
        'mingw-w64-x86_64-gcc',
        'mingw-w64-x86_64-make',
        'mingw-w64-x86_64-gdb',
        'mingw-w64-x86_64-binutils',
        'mingw-w64-x86_64-vtk',
        'mingw-w64-x86_64-qt6',
        'mingw-w64-x86_64-opencv',
        'mingw-w64-x86_64-nlohmann-json',
        'mingw-w64-x86_64-jsoncpp',
        'mingw-w64-x86_64-usrsctp',
        'mingw-w64-x86_64-libsrtp',
        'mingw-w64-x86_64-gst-plugins-base',
        'mingw-w64-x86_64-gst-plugins-good',
        'mingw-w64-x86_64-gst-plugins-bad',
        'mingw-w64-x86_64-gst-plugins-ugly',
        'mingw-w64-x86_64-gst-libav',
        'mingw-w64-x86_64-freetype',
        'mingw-w64-x86_64-fast_float',
        'mingw-w64-x86_64-utf8cpp',
        'mingw-w64-x86_64-eigen3',
        'mingw-w64-x86_64-pkg-config',
        'mingw-w64-x86_64-openssl',
        'mingw-w64-x86_64-libzip',
        'mingw-w64-x86_64-vulkan-devel',
        'mingw-w64-x86_64-vulkan',
        'mingw-w64-x86_64-vulkan-headers'
    ) -Message 'MSYS2 dependency snapshot is incorrect'
}

Invoke-Test 'vcpkg definition freezes tag, registries, and SonoBot manifests' {
    $definition = Read-PackageDefinition -Id 'vcpkg-sonosystem'
    Assert-Equal -Actual $definition.vcpkgTag -Expected '2025.12.12' -Message 'vcpkg tag is incorrect'
    Assert-Equal -Actual @($definition.registryBaselines) -Expected @(
        '544a4c5c297e60e4ac4a5a1810df66748d908869',
        '054637a2ae63c6c647b3169251759910cc4c984a'
    ) -Message 'vcpkg registry baselines are incorrect'
    Assert-Equal -Actual @($definition.manifestTree.path) -Expected @('vcpkg.json', 'vcpkg-configuration.json') -Message 'vcpkg manifest tree is incomplete'
    foreach ($entry in @($definition.manifestTree)) {
        if ([string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "vcpkg manifest '$($entry.path)' has no exact SHA-256." }
    }
}

Invoke-Test 'Boost, libdatachannel, and CMake source pins match SonoBot' {
    $mingw = Read-PackageDefinition -Id 'boost-mingw'
    $msvc = Read-PackageDefinition -Id 'boost-msvc'
    $libdatachannel = Read-PackageDefinition -Id 'libdatachannel'
    $sources = Read-PackageDefinition -Id 'cmake-sources'
    Assert-Equal -Actual "$($mingw.version):$($mingw.toolchain)" -Expected '1.86.0:gcc14.2-mingw' -Message 'MinGW Boost pin is incorrect'
    Assert-Equal -Actual "$($msvc.version):$($msvc.toolchain)" -Expected '1.86.0:msvc19.43-v143' -Message 'MSVC Boost pin is incorrect'
    Assert-Equal -Actual $libdatachannel.version -Expected '0.21.2' -Message 'libdatachannel pin is incorrect'
    Assert-Equal -Actual @($sources.contents | ForEach-Object { "$($_.id)=$($_.version)" }) `
        -Expected @('spdlog=1.15.0', 'googletest=1.14.0') -Message 'CMake source pins are incorrect'
}

Invoke-Test 'CP210x definition requires signed Universal driver INF metadata' {
    $definition = Read-PackageDefinition -Id 'cp210x'
    Assert-Equal -Actual $definition.product -Expected 'CP210x Universal Windows Driver' -Message 'CP210x product is incorrect'
    Assert-Equal -Actual $definition.source.authenticode.status -Expected 'Valid' -Message 'CP210x must require a valid Authenticode signature'
    Assert-Equal -Actual $definition.source.inf.version -Expected $definition.version -Message 'CP210x version must come from its INF'
}

Write-Host "Catalog tests: $script:passed passed, $script:failed failed."
if ($script:failed -ne 0) {
    exit 1
}
