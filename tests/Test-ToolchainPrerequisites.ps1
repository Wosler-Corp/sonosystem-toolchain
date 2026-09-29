[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src/ToolchainPrerequisites.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Prerequisite module not found: $modulePath" }
Import-Module $modulePath -Force
$script:passed = 0
$script:failed = 0
function Assert-True($Value, $Message) { if (-not $Value) { throw $Message } }
function Invoke-Test($Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS: $Name" }
    catch { $script:failed++; Write-Host "FAIL: ${Name}: $($_.Exception.Message)" }
}
function Assert-Rejected([scriptblock]$Body, $Pattern) {
    try { & $Body | Out-Null } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)"
        Assert-True ($_.Exception.Message -match 'expected' -and $_.Exception.Message -match 'observed') 'Failure must include expected and observed values'
        return
    }
    throw 'Expected prerequisite rejection'
}
$root = Join-Path ([IO.Path]::GetTempPath()) "prerequisite-test-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $catalogPath = Join-Path $root 'catalog.json'
    $vsRoot = Join-Path $root 'Visual Studio'
    $vswhere = Join-Path $root 'vswhere.cmd'
    $response = Join-Path $root 'vswhere.json'
    $calls = Join-Path $root 'vswhere-calls.txt'
    [IO.File]::WriteAllLines($vswhere, @('@echo off', "echo %*>>`"$calls`"", "type `"$response`"", 'exit /b 0'))
    $outputPath = Join-Path $root 'result.json'
    $defaultTools = Join-Path $vsRoot 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
    $redistVersion = Join-Path $vsRoot 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt'
    $probeFiles = @('MSBuild/Current/Bin/MSBuild.exe', 'MSBuild/Microsoft/VC/v170/Platforms/x64/PlatformToolsets/v143/Toolset.props', 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe', 'VC/Tools/MSVC/14.43.34808/bin/Hostx64/x64/cl.exe', 'VC/Redist/MSVC/14.43.34808/x64/Microsoft.VC143.CRT/vcruntime140.dll')
    foreach ($relative in $probeFiles) {
        $path = Join-Path $vsRoot $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllText($path, 'synthetic probe placeholder')
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $defaultTools)) | Out-Null
    $script:compilerVersion = '19.43.34810'
    $script:msbuildVersion = '17.14.0.0'
    $script:cmakeGenerator = 'Visual Studio 17 2022'
    $probeRunner = {
        param($Path, $Arguments)
        if ($Path -like '*MSBuild.exe') {
            Assert-True (($Arguments -join ' ') -ceq '-version -nologo') 'Incorrect MSBuild probe arguments'
            return @{ ExitCode = 0; Output = $script:msbuildVersion }
        }
        if ($Path -like '*cl.exe') {
            Assert-True (($Arguments -join ' ') -ceq '/Bv') 'Incorrect compiler probe arguments'
            return @{ ExitCode = 0; Output = "Microsoft (R) C/C++ Optimizing Compiler Version $script:compilerVersion for x64" }
        }
        if ($Path -like '*cmake.exe') {
            Assert-True (($Arguments -join ' ') -ceq '-E capabilities') 'Incorrect CMake probe arguments'
            if ($script:malformedCMake) { return @{ ExitCode = 0; Output = '{}' } }
            return @{ ExitCode = 0; Output = (@{ generators = @(@{ name = $script:cmakeGenerator; toolsetSupport = $true }) } | ConvertTo-Json -Depth 5 -Compress) }
        }
        throw "Unexpected executable: $Path"
    }
    function Reset-Fixture {
        $script:catalog = Get-Content (Join-Path $PSScriptRoot 'fixtures/catalog-valid.json') -Raw | ConvertFrom-Json -Depth 100
        $script:instance = [pscustomobject]@{ productId = 'Microsoft.VisualStudio.Product.Enterprise'; installationVersion = '17.14.0.0'; installationPath = $vsRoot; isComplete = $true; isLaunchable = $true }
        $script:compilerVersion = '19.43.34810'; $script:msbuildVersion = '17.14.0.0'; $script:cmakeGenerator = 'Visual Studio 17 2022'
        $script:malformedCMake = $false
        [IO.File]::WriteAllText($defaultTools, '14.43.34808')
        [IO.File]::WriteAllText($redistVersion, '14.43.34808')
        if (Test-Path $outputPath) { Remove-Item -LiteralPath $outputPath }
    }
    function Write-Fixture {
        $script:catalog | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $catalogPath
        ConvertTo-Json -InputObject @($script:instance) -Depth 10 | Set-Content -LiteralPath $response
    }
    function Invoke-Prerequisites($Context = 'ci', $Label = 'windows-latest-l') {
        Test-ToolchainPrerequisites -CatalogPath $catalogPath -Context $Context -RunnerImage $Label -VsWherePath $vswhere -ProbeRunner $probeRunner -OutputPath $outputPath
    }
    Invoke-Test 'exact product components and tool versions produce canonical successful evidence' {
        Reset-Fixture; Write-Fixture
        $result = Invoke-Prerequisites
        Assert-True ($result.catalogSha256 -ceq (Get-FileHash $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Catalog digest missing'
        Assert-True ($result.prerequisites[0].compilerVersion -ceq '19.43.34810') 'Compiler evidence missing'
        Assert-True ((Get-Content $outputPath -Raw | ConvertFrom-Json).context -ceq 'ci') 'JSON evidence missing'
        $arguments = Get-Content $calls -Raw
        foreach ($component in $script:catalog.runnerPrerequisites[0].requiredComponents) { Assert-True ($arguments.Contains($component)) "vswhere did not require $component" }
        Assert-True ($arguments.Contains('Microsoft.VisualStudio.Product.Enterprise') -and $arguments.Contains('[17.0,18.0)')) 'Product and version query was not exact'
    }
    foreach ($case in @(
        @{ Name = 'missing product'; Pattern = 'product'; Change = { $script:instance = $null } },
        @{ Name = 'wrong product'; Pattern = 'product'; Change = { $script:instance.productId = 'Microsoft.VisualStudio.Product.Community' } },
        @{ Name = 'wrong installation version'; Pattern = 'installationVersion'; Change = { $script:instance.installationVersion = '17.13.0.0' } },
        @{ Name = 'wrong tools version'; Pattern = 'vcToolsVersion'; Change = { [IO.File]::WriteAllText($defaultTools, '14.42.00000') } },
        @{ Name = 'wrong compiler'; Pattern = 'compilerVersion'; Change = { $script:compilerVersion = '19.42.00000' } },
        @{ Name = 'wrong MSBuild'; Pattern = 'msbuildVersion'; Change = { $script:msbuildVersion = '17.13.0.0' } },
        @{ Name = 'missing CMake generator'; Pattern = 'generator'; Change = { $script:cmakeGenerator = 'Ninja' } },
        @{ Name = 'wrong toolset'; Pattern = 'toolset'; Change = { $script:catalog.runnerPrerequisites[0].toolset = 'v142' } }
    )) {
        Invoke-Test $case.Name {
            Reset-Fixture; & $case.Change; Write-Fixture
            Assert-Rejected { Invoke-Prerequisites } $case.Pattern
            Assert-True (-not (Test-Path $outputPath)) 'Failure wrote successful evidence'
        }
    }
    Invoke-Test 'one missing component is reported before tool probes' {
        Reset-Fixture; Write-Fixture
        # vswhere filters a product out when any required component is absent.
        [IO.File]::WriteAllText($response, '[]')
        Assert-Rejected { Invoke-Prerequisites } 'Microsoft.VisualStudio.Component.VC.CMake.Project'
    }
    Invoke-Test 'malformed vswhere output fails closed' {
        Reset-Fixture; Write-Fixture; [IO.File]::WriteAllText($response, 'not json')
        Assert-Rejected { Invoke-Prerequisites } 'JSON'
    }
    Invoke-Test 'malformed CMake capabilities report expected and observed values' {
        Reset-Fixture; Write-Fixture; $script:malformedCMake = $true
        Assert-Rejected { Invoke-Prerequisites } 'CMake.*expected.*observed'
    }
    foreach ($relative in $probeFiles) {
        Invoke-Test "missing installed probe payload $relative fails closed" {
            Reset-Fixture; Write-Fixture
            $path = Join-Path $vsRoot $relative
            Remove-Item -LiteralPath $path
            try { Assert-Rejected { Invoke-Prerequisites } 'expected.*observed' }
            finally { [IO.File]::WriteAllText($path, 'synthetic probe placeholder') }
        }
    }
    Invoke-Test 'redist version is observed without imposing an unapproved exact pin' {
        Reset-Fixture; Write-Fixture
        $alternatePayload = Join-Path $vsRoot 'VC/Redist/MSVC/14.44.00000/x64/Microsoft.VC143.CRT/vcruntime140.dll'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $alternatePayload)) | Out-Null
        [IO.File]::WriteAllText($alternatePayload, 'synthetic runtime')
        [IO.File]::WriteAllText($redistVersion, '14.44.00000')
        $result = Invoke-Prerequisites
        Assert-True ($result.prerequisites[0].redistVersion -ceq '14.44.00000') 'Observed redist version not reported'
    }
    Invoke-Test 'wrong runner label fails before vswhere and asset access' {
        Reset-Fixture; Write-Fixture
        $before = (Get-Content $calls).Count
        Assert-Rejected { Invoke-Prerequisites 'ci' 'windows-latest' } 'windows-latest-l.*windows-latest'
        Assert-True ((Get-Content $calls).Count -eq $before) 'Wrong label invoked vswhere'
    }
    Invoke-Test 'developer contract succeeds without a runner label' {
        Reset-Fixture
        $script:catalog.runnerPrerequisites[0].context = 'developer'
        $script:catalog.runnerPrerequisites[0].productId = 'Microsoft.VisualStudio.Product.Community'
        $script:instance.productId = 'Microsoft.VisualStudio.Product.Community'
        Write-Fixture
        $result = Invoke-Prerequisites 'developer' ''
        Assert-True ($result.context -ceq 'developer') 'Developer context was not honored'
    }
    Invoke-Test 'unapproved developer product context fails closed' {
        Reset-Fixture; Write-Fixture
        Assert-Rejected { Invoke-Prerequisites 'developer' '' } 'developer'
    }
    Invoke-Test 'online CI installer rejects prerequisites before synchronizing assets or creating install state' {
        Reset-Fixture; Write-Fixture
        Import-Module (Join-Path $repoRoot 'src/ToolchainInstall.psm1') -Force
        $installRoot = Join-Path $root 'installed'
        Assert-Rejected { Install-ToolchainProfile -CatalogPath $catalogPath -Profile ci-windows -InstallRoot $installRoot -RunnerImage 'wrong-label' -GitHubCliPath (Join-Path $root 'must-not-run.cmd') } 'runner'
        Assert-True (-not (Test-Path $installRoot)) 'Prerequisite failure created installation files'
    }
} finally {
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host "Prerequisite tests: $script:passed passed, $script:failed failed."
if ($script:failed -gt 0) { exit 1 }
