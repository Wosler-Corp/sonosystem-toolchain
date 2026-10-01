[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$syncPath = Join-Path $repoRoot 'scripts/Sync-ToolchainAssets.ps1'
if (-not (Test-Path -LiteralPath $syncPath)) { throw "Asset synchronization script not found: $syncPath" }
$script:passed = 0; $script:failed = 0
function Assert-True($Value, $Message) { if (-not $Value) { throw $Message } }
function Invoke-Test($Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS: $Name" }
    catch { $script:failed++; Write-Host "FAIL: ${Name}: $($_.Exception.Message)" }
}
function Assert-Rejected([scriptblock]$Body, $Pattern) {
    try { & $Body | Out-Null } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)"
        return
    }
    throw 'Expected synchronization rejection'
}
$root = Join-Path ([IO.Path]::GetTempPath()) "asset-sync-test-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $source = Join-Path $root 'source'
    [IO.Directory]::CreateDirectory($source) | Out-Null
    $catalogPath = Join-Path $root 'catalog.json'
    $cacheRoot = Join-Path $root 'cache'
    $log = Join-Path $root 'gh-log.jsonl'
    $modeFile = Join-Path $root 'mode.txt'
    $counter = Join-Path $root 'attempt.txt'
    $fakeScript = Join-Path $root 'gh.ps1'
    $gh = Join-Path $root 'gh.cmd'
    # The fake is a process boundary: real release argv, disk writes, and exit status.
    $fakeBody = @'
$ErrorActionPreference = 'Stop'
$a = @($args)
ConvertTo-Json -InputObject $a -Compress | Add-Content -LiteralPath (Join-Path $PSScriptRoot 'gh-log.jsonl')
$mode = Get-Content (Join-Path $PSScriptRoot 'mode.txt') -Raw
if ($a[0] -cne 'release' -or $a -contains 'https://vendor.invalid') { throw 'Unexpected upstream access' }
$repoIndex = [Array]::IndexOf($a, '--repo')
if ($repoIndex -lt 0 -or $a[$repoIndex + 1] -cne 'Wosler-Corp/sonosystem-toolchain') { throw 'Unexpected repository' }
$countPath = Join-Path $PSScriptRoot 'attempt.txt'
$count = if (Test-Path $countPath) { [int](Get-Content $countPath) } else { 0 }
if ($mode -match '^(download|verify)-(\d{3})$' -and (($a[1] -ceq 'download' -and $Matches[1] -ceq 'download') -or ($a[1] -ceq 'verify-asset' -and $Matches[1] -ceq 'verify'))) {
    $status = $Matches[2]
    Set-Content $countPath ($count + 1)
    if ($count -eq 0 -or $status -eq '403') { Write-Output "HTTP $status release endpoint"; exit 1 }
}
if ($a[1] -ceq 'verify-asset') {
    if ($mode -eq 'attestation') { Write-Output 'invalid attestation signature'; exit 1 }
    if (-not (Test-Path -LiteralPath $a[3] -PathType Leaf)) { throw 'Verification bytes missing' }
    if ($a[2] -cne [IO.Path]::GetFileName($a[3]).Replace('-windows-x86_64.zip', '')) { throw 'Wrong verification tag' }
    exit 0
}
if ($a[1] -cne 'download') { throw 'Unexpected gh operation' }
$asset = $a[[Array]::IndexOf($a, '--pattern') + 1]
$dir = $a[[Array]::IndexOf($a, '--dir') + 1]
if ($a[2] -cne $asset.Replace('-windows-x86_64.zip', '')) { throw 'Wrong tag' }
if ($mode -eq 'no-file') { exit 0 }
Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'source') $asset) -Destination (Join-Path $dir $asset)
if ($mode -eq 'bad-download') { [IO.File]::WriteAllText((Join-Path $dir $asset), 'BAD!') }
if ($mode -eq 'wrong-digest') { $target = Join-Path $dir $asset; [IO.File]::WriteAllText($target, ('x' * (Get-Item $target).Length)) }
exit 0
'@
    [IO.File]::WriteAllText($fakeScript, $fakeBody)
    [IO.File]::WriteAllLines($gh, @('@echo off', "`"$PSHOME\pwsh.exe`" -NoProfile -File `"$fakeScript`" %*", 'exit /b %errorlevel%'))
    function Reset-Fixture {
        $script:catalog = Get-Content (Join-Path $PSScriptRoot 'fixtures/catalog-valid.json') -Raw | ConvertFrom-Json -Depth 100
        foreach ($package in $script:catalog.packages) {
            $assetPath = Join-Path $source $package.release.asset
            [IO.File]::WriteAllText($assetPath, "synthetic-$($package.id)")
            $package.release.sizeBytes = (Get-Item $assetPath).Length
            $package.release.sha256 = (Get-FileHash $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $script:catalog | ConvertTo-Json -Depth 100 | Set-Content $catalogPath
        $script:hash = (Get-FileHash $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:flatRoot = Join-Path $cacheRoot $script:hash
        foreach ($path in @($cacheRoot, $log, $counter)) { if (Test-Path $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
        [IO.File]::WriteAllText($modeFile, 'success')
    }
    function Invoke-Sync { & $syncPath -CatalogPath $catalogPath -Profile ci-windows -AssetCacheRoot $cacheRoot -GitHubCliPath $gh }
    function Get-Calls { if (Test-Path $log) { foreach ($line in Get-Content $log) { ,(ConvertFrom-Json $line) } } }
    function Assert-Cache($Result) {
        Assert-True ($Result.catalogSha256 -ceq $script:hash) 'Wrong catalog hash'
        Assert-True ($Result.assetRoot -ceq $script:flatRoot) 'Cache did not use exact catalog hash'
        Assert-True (@($Result.assets).Count -eq 2) 'Dependency closure missing or extra assets included'
        foreach ($asset in $Result.assets) {
            Assert-True ((Split-Path -Parent $asset.path) -ceq $script:flatRoot) 'Asset was not directly under hash directory'
            $package = $script:catalog.packages | Where-Object id -CEQ $asset.id
            Assert-True ((Get-Item $asset.path).Length -eq $package.release.sizeBytes) 'Wrong cached byte count'
            Assert-True ((Get-FileHash $asset.path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $package.release.sha256) 'Wrong cached digest'
        }
        Assert-True (@(Get-ChildItem $script:flatRoot -Recurse -File).Count -eq 2) 'Temporary files leaked into cache'
        Assert-True ((Get-Content $log -Raw) -notmatch 'vendor.invalid|silabs.com|https://') 'Upstream URL reached a process'
    }
    Invoke-Test 'empty cache downloads and verifies dependency closure under exact hash' {
        Reset-Fixture; $result = Invoke-Sync; Assert-Cache $result
        Assert-True (@($result.downloads).Count -eq 2 -and @($result.cacheHits).Count -eq 0) 'Incorrect download summary'
    }
    Invoke-Test 'valid cache is byte-checked and online-attested without downloading' {
        Reset-Fixture; Invoke-Sync | Out-Null; Remove-Item -LiteralPath $log
        $result = Invoke-Sync; Assert-Cache $result
        Assert-True (@($result.cacheHits).Count -eq 2 -and @($result.downloads).Count -eq 0) 'Cache hit summary incorrect'
        Assert-True (@(Get-Calls | Where-Object { $_[1] -eq 'download' }).Count -eq 0) 'Valid cache downloaded again'
        Assert-True (@(Get-Calls | Where-Object { $_[1] -eq 'verify-asset' }).Count -eq 2) 'Cache hit skipped online attestation'
    }
    foreach ($damage in @('missing', 'wrong size', 'wrong digest')) {
        Invoke-Test "repairs $damage cache entry atomically" {
            Reset-Fixture; Invoke-Sync | Out-Null
            $target = Join-Path $script:flatRoot $script:catalog.packages[0].release.asset
            if ($damage -eq 'missing') { Remove-Item -LiteralPath $target }
            elseif ($damage -eq 'wrong size') { [IO.File]::WriteAllText($target, 'bad') }
            else { [IO.File]::WriteAllText($target, ('x' * (Get-Item $target).Length)) }
            $result = Invoke-Sync; Assert-Cache $result
            Assert-True (@($result.downloads).Count -eq 1) 'Wrong number of repaired entries'
            Assert-True (@($result.replacedCorruptEntries).Count -eq $(if ($damage -eq 'missing') { 0 } else { 1 })) 'Incorrect corrupt summary'
        }
    }
    Invoke-Test 'failed attestation preserves corrupt previous bytes and removes temporary download' {
        Reset-Fixture; Invoke-Sync | Out-Null
        $target = Join-Path $script:flatRoot $script:catalog.packages[0].release.asset
        [IO.File]::WriteAllText($target, 'old-corrupt-bytes'); [IO.File]::WriteAllText($modeFile, 'attestation')
        Assert-Rejected { Invoke-Sync } 'attestation'
        Assert-True ((Get-Content $target -Raw) -ceq 'old-corrupt-bytes') 'Failed verification replaced the old entry'
        Assert-True (@(Get-ChildItem $script:flatRoot -Recurse -File).Count -eq 2) 'Failed download leaked temporary files'
    }
    Invoke-Test 'valid cached bytes still fail closed on attestation failure' {
        Reset-Fixture; Invoke-Sync | Out-Null; [IO.File]::WriteAllText($modeFile, 'attestation')
        Assert-Rejected { Invoke-Sync } 'attestation'
    }
    foreach ($mode in @('bad-download', 'wrong-digest', 'no-file')) {
        Invoke-Test "rejects $mode without committing cache bytes" {
            Reset-Fixture; [IO.File]::WriteAllText($modeFile, $mode)
            Assert-Rejected { Invoke-Sync } 'size|missing|Verification|SHA-256'
            Assert-True (@(Get-ChildItem $script:flatRoot -Recurse -File).Count -eq 0) 'Invalid bytes committed'
        }
    }
    foreach ($operation in @('download', 'verify')) {
        foreach ($status in @('408', '429', '503')) {
            Invoke-Test "$operation HTTP $status retries Wosler release access" {
                Reset-Fixture; [IO.File]::WriteAllText($modeFile, "$operation-$status")
                $result = Invoke-Sync; Assert-Cache $result
                Assert-True ([int](Get-Content $counter) -eq 3) 'Transient operation was not retried once before processing next asset'
            }
        }
    }
    Invoke-Test 'HTTP 403 does not retry' {
        Reset-Fixture; [IO.File]::WriteAllText($modeFile, 'download-403')
        Assert-Rejected { Invoke-Sync } '403'
        Assert-True ([int](Get-Content $counter) -eq 1) 'Non-transient failure retried'
    }
    Invoke-Test 'new catalog bytes cannot reuse old catalog hash directory' {
        Reset-Fixture; Invoke-Sync | Out-Null
        Add-Content $catalogPath ' '
        $script:hash = (Get-FileHash $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:flatRoot = Join-Path $cacheRoot $script:hash
        $result = Invoke-Sync; Assert-Cache $result
        Assert-True (@($result.cacheHits).Count -eq 0) 'Changed catalog reused old cache'
    }
    foreach ($alias in @(
        @{ Name = 'identical'; Suffix = ''; Uppercase = $false },
        @{ Name = 'case-only'; Suffix = ''; Uppercase = $true },
        @{ Name = 'trailing-dot'; Suffix = '.'; Uppercase = $false },
        @{ Name = 'trailing-space'; Suffix = ' '; Uppercase = $false }
    )) {
        Invoke-Test "conflicting $($alias.Name) Windows asset names fail before network or cache mutation" {
            Reset-Fixture
            $name = [string]$script:catalog.packages[0].release.asset
            if ($alias.Uppercase) { $name = $name.ToUpperInvariant() }
            $script:catalog.packages[1].release.asset = $name + $alias.Suffix
            $script:catalog | ConvertTo-Json -Depth 100 | Set-Content $catalogPath
            Assert-Rejected { Invoke-Sync } 'duplicate.*asset|noncanonical.*asset'
            Assert-True (-not (Test-Path $log)) 'Conflicting catalog reached network access'
            Assert-True (-not (Test-Path $cacheRoot)) 'Conflicting catalog mutated the cache'
        }
    }
} finally {
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host "Asset synchronization tests: $script:passed passed, $script:failed failed."
if ($script:failed -gt 0) { exit 1 }
