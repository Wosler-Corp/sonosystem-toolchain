[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolverPath = Join-Path $repoRoot 'scripts\Resolve-ToolchainCatalog.ps1'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\catalog-valid.json'
$script:passed = 0
$script:failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message Expected '$Expected', found '$Actual'." }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw 'Expected action to throw.' }
    catch {
        if ($_.Exception.Message -eq 'Expected action to throw.') { throw }
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected error matching '$Pattern', found '$($_.Exception.Message)'."
        }
    }
}

function Invoke-Test([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS: $Name" }
    catch { $script:failed++; Write-Host "FAIL: $Name`n$($_.Exception.Message)" }
}

function New-ResolverEnvironment {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('toolchain-resolver-test-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $source = Join-Path $root 'source-catalog.json'
    Copy-Item -LiteralPath $fixturePath -Destination $source
    $catalog = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
    foreach ($package in @($catalog.packages)) { $package.release.tag = 'windows-test-1.0.0' }
    [IO.File]::WriteAllText($source, ($catalog | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    $fakeGh = Join-Path $root 'fake-gh.ps1'
    $fakeSource = @'
$ErrorActionPreference = 'Stop'
[IO.File]::AppendAllText($env:FAKE_GH_LOG, (($args | ConvertTo-Json -Compress) + [Environment]::NewLine))
if ($args[0] -cne 'release') { exit 91 }
switch ($args[1]) {
    'view' {
        [pscustomobject]@{
            tagName = $args[2]
            isDraft = $env:FAKE_GH_DRAFT -ceq 'true'
            isImmutable = $env:FAKE_GH_IMMUTABLE -ceq 'true'
        } | ConvertTo-Json -Compress
        exit 0
    }
    'download' {
        $patternIndex = [Array]::IndexOf($args, '--pattern')
        $directoryIndex = [Array]::IndexOf($args, '--dir')
        if ($patternIndex -lt 0 -or $directoryIndex -lt 0) { exit 92 }
        Copy-Item -LiteralPath $env:FAKE_GH_SOURCE -Destination (Join-Path $args[$directoryIndex + 1] $args[$patternIndex + 1])
        exit 0
    }
    'verify-asset' {
        if ($env:FAKE_GH_VERIFY_EXIT) { exit [int]$env:FAKE_GH_VERIFY_EXIT }
        exit 0
    }
}
exit 93
'@
    [IO.File]::WriteAllText($fakeGh, $fakeSource, [Text.UTF8Encoding]::new($false))
    $log = Join-Path $root 'gh-calls.jsonl'
    $env:FAKE_GH_SOURCE = $source
    $env:FAKE_GH_LOG = $log
    $env:FAKE_GH_DRAFT = 'false'
    $env:FAKE_GH_IMMUTABLE = 'true'
    $env:FAKE_GH_VERIFY_EXIT = ''
    return [pscustomobject]@{
        Root = $root
        Source = $source
        FakeGh = $fakeGh
        Log = $log
        Output = Join-Path $root 'resolved\catalog.json'
    }
}

function Remove-ResolverEnvironment($Environment) {
    Remove-Item -LiteralPath $Environment.Root -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-Test 'resolves one exact immutable Wosler catalog asset and verifies it before use' {
    $environment = New-ResolverEnvironment
    try {
        $expectedHash = (Get-FileHash -LiteralPath $environment.Source -Algorithm SHA256).Hash.ToLowerInvariant()
        $result = & $resolverPath -ReleaseTag 'windows-test-1.0.0' -AssetName 'catalog-valid.json' `
            -ExpectedSha256 $expectedHash -OutputPath $environment.Output -GitHubCliPath $environment.FakeGh
        Assert-True (Test-Path -LiteralPath $environment.Output -PathType Leaf) 'Resolved catalog was not created.'
        Assert-Equal $result.catalogId 'windows-2026.09.0' 'Resolved catalog ID differs.'
        Assert-Equal $result.catalogSha256 $expectedHash 'Resolved catalog SHA-256 differs.'
        $calls = @(Get-Content -LiteralPath $environment.Log | ForEach-Object { ,($_ | ConvertFrom-Json) })
        Assert-Equal $calls.Count 3 'Resolver must make exactly view, download, and verify calls.'
        Assert-True ($calls[0] -join ' ' -match '^release view windows-test-1\.0\.0 .*--repo Wosler-Corp/sonosystem-toolchain') 'Release view was not exact.'
        Assert-True ($calls[1] -join ' ' -match '^release download windows-test-1\.0\.0 .*--repo Wosler-Corp/sonosystem-toolchain .*--pattern catalog-valid\.json') 'Release download was not exact.'
        Assert-True ($calls[2] -join ' ' -match '^release verify-asset windows-test-1\.0\.0 .*--repo Wosler-Corp/sonosystem-toolchain') 'Asset attestation verification was not exact.'
    } finally { Remove-ResolverEnvironment $environment }
}

Invoke-Test 'rejects a caller digest mismatch before parsing the downloaded catalog' {
    $environment = New-ResolverEnvironment
    try {
        [IO.File]::WriteAllText($environment.Source, '{not-json', [Text.UTF8Encoding]::new($false))
        Assert-Throws {
            & $resolverPath -ReleaseTag 'windows-test-1.0.0' -AssetName 'catalog-valid.json' `
                -ExpectedSha256 ('0' * 64) -OutputPath $environment.Output -GitHubCliPath $environment.FakeGh
        } 'SHA-256'
    } finally { Remove-ResolverEnvironment $environment }
}

Invoke-Test 'rejects a draft release before downloading any catalog bytes' {
    $environment = New-ResolverEnvironment
    try {
        $env:FAKE_GH_DRAFT = 'true'
        $env:FAKE_GH_IMMUTABLE = 'false'
        $expectedHash = (Get-FileHash -LiteralPath $environment.Source -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Throws {
            & $resolverPath -ReleaseTag 'windows-test-1.0.0' -AssetName 'catalog-valid.json' `
                -ExpectedSha256 $expectedHash -OutputPath $environment.Output -GitHubCliPath $environment.FakeGh
        } 'draft|immutable'
        $calls = @(Get-Content -LiteralPath $environment.Log)
        Assert-Equal $calls.Count 1 'Draft rejection performed a download or verification call.'
    } finally { Remove-ResolverEnvironment $environment }
}

Invoke-Test 'composite action exposes the exact setup interface and orchestration order' {
    $actionPath = Join-Path $repoRoot 'actions\setup-windows-toolchain\action.yml'
    Assert-True (Test-Path -LiteralPath $actionPath -PathType Leaf) 'Reusable setup action is missing.'
    $text = Get-Content -LiteralPath $actionPath -Raw
    foreach ($inputName in @('catalog-release-tag', 'catalog-asset-name', 'catalog-sha256', 'profile', 'install-root', 'trusted-cache-save')) {
        Assert-True ($text -match "(?m)^  $([regex]::Escape($inputName)):\s*$") "Action input '$inputName' is missing."
    }
    foreach ($outputName in @('catalog-id', 'catalog-sha256', 'installed-state-path', 'prerequisite-result-path', 'cache-hit', 'assets-downloaded')) {
        Assert-True ($text -match "(?m)^  $([regex]::Escape($outputName)):\s*$") "Action output '$outputName' is missing."
    }
    $markers = [ordered]@{
        resolve = 'Resolve-ToolchainCatalog.ps1'
        prerequisites = 'Test-ToolchainPrerequisites.ps1'
        restore = 'actions/cache/restore@'
        sync = 'Sync-ToolchainAssets.ps1'
        install = 'Install-ToolchainProfile.ps1'
        validate = 'Test-InstalledToolchain.ps1'
        save = 'actions/cache/save@'
    }
    $positions = @{}
    foreach ($entry in $markers.GetEnumerator()) {
        $positions[$entry.Key] = $text.IndexOf($entry.Value, [StringComparison]::Ordinal)
        Assert-True ($positions[$entry.Key] -ge 0) "Action step '$($entry.Key)' is missing."
    }
    $orderedNames = @('resolve', 'prerequisites', 'restore', 'sync', 'install', 'validate', 'save')
    for ($index = 1; $index -lt $orderedNames.Count; $index++) {
        Assert-True ($positions[$orderedNames[$index - 1]] -lt $positions[$orderedNames[$index]]) `
            "Action order is wrong around '$($orderedNames[$index - 1])' and '$($orderedNames[$index])'."
    }
    Assert-True ($text -match "-RunnerImage\s+'windows-latest-l'") 'Licensed runner preflight is not exact.'
    Assert-True ($text -match '-OfflineAssetRoot\s+\$env:ASSET_ROOT') 'Installer does not consume the verified flat asset root.'
}

Invoke-Test 'composite action uses an exact digest cache and trusted non-PR save' {
    $actionPath = Join-Path $repoRoot 'actions\setup-windows-toolchain\action.yml'
    Assert-True (Test-Path -LiteralPath $actionPath -PathType Leaf) 'Reusable setup action is missing.'
    $text = Get-Content -LiteralPath $actionPath -Raw
    $uses = @([regex]::Matches($text, '(?m)^\s*uses:\s*([^\s#]+)') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($uses.Count -eq 2) 'Composite action must use only cache restore and cache save actions.'
    Assert-True (@($uses | Where-Object { $_ -notmatch '^actions/cache/(restore|save)@[a-f0-9]{40}$' }).Count -eq 0) `
        'Every external composite-action dependency must be pinned by full commit SHA.'
    Assert-True ($text -notmatch '(?m)^\s*restore-keys:') 'Cache restore prefixes are prohibited.'
    Assert-True ($text -match "key:\s*[^\r\n]*\$\{\{\s*steps\.catalog\.outputs\.catalog-sha256\s*\}\}") `
        'Cache key does not contain the complete resolved catalog digest.'
    Assert-True ($text -match "inputs\.trusted-cache-save\s*==\s*'true'") 'Trusted cache-save input is not enforced.'
    Assert-True ($text -match "github\.event_name\s*!=\s*'pull_request'") 'Pull requests are not excluded from cache save.'
    Assert-True ($text -match "steps\.cache-restore\.outputs\.cache-hit\s*!=\s*'true'") 'Cache hits are not excluded from save.'
}

Invoke-Test 'validation workflow runs the workflow contract suite with full action pins' {
    $workflowPath = Join-Path $repoRoot '.github\workflows\validate-toolchain.yml'
    $text = Get-Content -LiteralPath $workflowPath -Raw
    Assert-True ($text -match 'tests/Test-WorkflowContracts\.ps1') 'Workflow contract suite is not run in CI.'
    $externalUses = @([regex]::Matches($text, '(?m)^\s*uses:\s*(actions/[^\s#]+)') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($externalUses.Count -gt 0) 'Validation workflow has no pinned checkout action.'
    Assert-True (@($externalUses | Where-Object { $_ -notmatch '^actions/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)?@[a-f0-9]{40}$' }).Count -eq 0) `
        'Validation workflow contains a floating external action reference.'
}

Write-Host "Workflow contract tests: $script:passed passed, $script:failed failed."
if ($script:failed -ne 0) { exit 1 }
