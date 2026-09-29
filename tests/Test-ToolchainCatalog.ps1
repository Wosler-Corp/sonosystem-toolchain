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

Write-Host "Catalog tests: $script:passed passed, $script:failed failed."
if ($script:failed -ne 0) {
    exit 1
}
