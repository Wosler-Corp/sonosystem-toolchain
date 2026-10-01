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
        return
    }
    throw 'Expected prerequisite rejection'
}

$root = Join-Path ([IO.Path]::GetTempPath()) "prerequisite-test-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $catalogPath = Join-Path $root 'catalog.json'
    $outputPath = Join-Path $root 'result.json'
    $vswherePath = Join-Path $root 'vswhere.exe'
    [IO.File]::WriteAllText($vswherePath, 'synthetic vswhere')
    $vsRoot = Join-Path $root 'Visual Studio'
    $toolsVersion = '14.43.34808'
    $defaultTools = Join-Path $vsRoot 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
    $redistVersion = Join-Path $vsRoot 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt'
    $probeFiles = @(
        'MSBuild/Current/Bin/MSBuild.exe',
        'MSBuild/Microsoft/VC/v170/Platforms/x64/PlatformToolsets/v143/Toolset.props',
        'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe',
        "VC/Tools/MSVC/$toolsVersion/bin/Hostx64/x64/cl.exe",
        "VC/Redist/MSVC/$toolsVersion/x64/Microsoft.VC143.CRT/vcruntime140.dll",
        'Common7/Tools/VsDevCmd.bat'
    )
    foreach ($relative in $probeFiles) {
        $path = Join-Path $vsRoot $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllText($path, 'synthetic probe placeholder')
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $defaultTools)) | Out-Null

    function Reset-Fixture {
        $script:catalog = Get-Content (Join-Path $PSScriptRoot 'fixtures/catalog-valid.json') -Raw | ConvertFrom-Json -Depth 100
        $script:detected = $true
        $script:productId = 'Microsoft.VisualStudio.Product.Enterprise'
        $script:installationVersion = '17.14.0.0'
        $script:compilerVersion = '19.43.34810'
        $script:msbuildVersion = '17.14.0.0'
        $script:sdkVersion = '10.0.26100.0'
        $script:cmakeGenerator = 'Visual Studio 17 2022'
        $script:signatureStatus = 'Valid'
        $script:signatureSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        $script:installerExitCode = 0
        $script:installerMakesAvailable = $true
        $script:downloadCount = 0
        $script:installCount = 0
        $script:vswhereCalls = [Collections.Generic.List[object]]::new()
        $script:sdkProbeArguments = $null
        [IO.File]::WriteAllText($defaultTools, $toolsVersion)
        [IO.File]::WriteAllText($redistVersion, $toolsVersion)
        if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath }
    }
    function Write-Fixture { $script:catalog | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $catalogPath }
    $vswhereRunner = {
        param($Path, $Arguments)
        $script:vswhereCalls.Add(@($Arguments))
        if (-not $script:detected) { return @{ ExitCode = 0; Output = '[]' } }
        $instance = [ordered]@{
            productId = $script:productId
            installationVersion = $script:installationVersion
            installationPath = $vsRoot
            isComplete = $true
            isLaunchable = $true
        }
        return @{ ExitCode = 0; Output = (ConvertTo-Json -InputObject @($instance) -Depth 10 -Compress) }
    }
    $probeRunner = {
        param($Path, $Arguments)
        if ($Path -like '*MSBuild.exe') { return @{ ExitCode = 0; Output = $script:msbuildVersion } }
        if ($Path -like '*cl.exe') { return @{ ExitCode = 2; Output = "Microsoft (R) C/C++ Optimizing Compiler Version $script:compilerVersion for x64" } }
        if ($Path -like '*cmake.exe') { return @{ ExitCode = 0; Output = (@{ generators = @(@{ name = $script:cmakeGenerator; toolsetSupport = $true }) } | ConvertTo-Json -Depth 5 -Compress) } }
        if ($Path -ieq $env:ComSpec) {
            $script:sdkProbeArguments = @($Arguments)
            return @{ ExitCode = 0; Output = $script:sdkVersion }
        }
        throw "Unexpected executable: $Path"
    }
    $downloadRunner = {
        param($Uri, $Destination)
        $script:downloadCount++
        [IO.File]::WriteAllText($Destination, 'synthetic Microsoft bootstrapper')
    }
    $signatureRunner = { param($Path); return @{ Status = $script:signatureStatus; SignerSubject = $script:signatureSubject } }
    $installerRunner = {
        param($Path, $Arguments)
        $script:installCount++
        if ($script:installerMakesAvailable) { $script:detected = $true }
        return @{ ExitCode = $script:installerExitCode; Output = 'synthetic installer output' }
    }
    function Invoke-Prerequisites($Context = 'ci', $Label = 'windows-latest-l', [switch]$MinGWOnly) {
        Test-ToolchainPrerequisites -CatalogPath $catalogPath -Context $Context -RunnerImage $Label `
            -VsWherePath $vswherePath -VsWhereRunner $vswhereRunner -ProbeRunner $probeRunner `
            -DownloadRunner $downloadRunner -SignatureRunner $signatureRunner -InstallerRunner $installerRunner `
            -TemporaryDirectory $root -OutputPath $outputPath -MinGWOnly:$MinGWOnly
    }

    foreach ($edition in @('Enterprise', 'Community', 'Professional', 'BuildTools')) {
        Invoke-Test "existing VS2022 $edition with all components is accepted without download" {
            Reset-Fixture; $script:productId = "Microsoft.VisualStudio.Product.$edition"; Write-Fixture
            $result = Invoke-Prerequisites
            Assert-True ($script:downloadCount -eq 0 -and $script:installCount -eq 0) 'Existing installation was modified'
            Assert-True ($result.prerequisites[0].productId -ceq $script:productId) 'Observed edition was not recorded'
            Assert-True ($result.prerequisites[0].installationVersion -ceq '17.14.0.0') 'Installation version evidence missing'
            Assert-True ($result.prerequisites[0].vcToolsVersion -ceq $toolsVersion) 'VC tools evidence missing'
            Assert-True ($result.prerequisites[0].compilerOutput -match $script:compilerVersion) 'Compiler /Bv evidence missing'
            Assert-True ($result.prerequisites[0].msbuildVersion -ceq $script:msbuildVersion) 'MSBuild evidence missing'
            Assert-True ($result.prerequisites[0].windowsSdkVersion -ceq $script:sdkVersion) 'Windows SDK evidence missing'
            $arguments = @($script:vswhereCalls[0])
            Assert-True (($arguments -join ' ') -match '-products \*') 'vswhere did not search all products'
            Assert-True (($arguments -join ' ') -match '\[17\.0,18\.0\)') 'vswhere version family differs'
            foreach ($component in $script:catalog.runnerPrerequisites[0].requiredComponents) {
                Assert-True ($arguments -ccontains $component) "vswhere did not require $component"
            }
        }
    }

    Invoke-Test 'Windows SDK probe reads the value after VsDevCmd initializes the environment' {
        Reset-Fixture; Write-Fixture
        Invoke-Prerequisites | Out-Null
        Assert-True ($script:sdkProbeArguments -ccontains '/v:on') 'SDK probe did not enable delayed expansion.'
        $command = [string]$script:sdkProbeArguments[-1]
        Assert-True ($command -match '!WindowsSDKVersion!') 'SDK probe did not read the post-VsDevCmd SDK value.'
        Assert-True ($command -notmatch '%WindowsSDKVersion%') 'SDK probe still expands the SDK value before VsDevCmd runs.'
    }

    Invoke-Test 'mutable Visual Studio and compiler patch versions are observed but not pinned' {
        Reset-Fixture; $script:installationVersion = '17.99.12345.6'; $script:compilerVersion = '19.99.12345'; $script:msbuildVersion = '17.99.1.0'; Write-Fixture
        $result = Invoke-Prerequisites
        Assert-True ($result.prerequisites[0].installationVersion -ceq $script:installationVersion) 'Installation patch was not observed'
        Assert-True ($result.prerequisites[0].msbuildVersion -ceq $script:msbuildVersion) 'MSBuild patch was not observed'
    }
    Invoke-Test 'VS2026-only machine triggers signed VS2022 Build Tools installation' {
        Reset-Fixture; $script:detected = $false; Write-Fixture
        $result = Invoke-Prerequisites
        Assert-True ($script:downloadCount -eq 1 -and $script:installCount -eq 1) 'Bootstrap install was not attempted once'
        Assert-True ($script:vswhereCalls.Count -eq 2) 'Detection was not repeated after installation'
        Assert-True ($result.prerequisites[0].productId -match 'Enterprise') 'Installed VS2022 was not detected'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'vs_BuildTools.exe'))) 'Temporary bootstrapper was not removed'
    }
    Invoke-Test 'missing component triggers installation and fails closed when still unavailable' {
        Reset-Fixture; $script:detected = $false; $script:installerMakesAvailable = $false; Write-Fixture
        Assert-Rejected { Invoke-Prerequisites } 'still unavailable|required components'
        Assert-True ($script:installCount -eq 1 -and $script:vswhereCalls.Count -eq 2) 'Fail-closed detection sequence differs'
    }
    foreach ($signatureCase in @(
        @{ Name = 'invalid'; Status = 'HashMismatch'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' },
        @{ Name = 'non-Microsoft'; Status = 'Valid'; Subject = 'CN=Contoso Ltd, O=Contoso Ltd' }
    )) {
        Invoke-Test "$($signatureCase.Name) bootstrapper signature is rejected before execution" {
            Reset-Fixture; $script:detected = $false; $script:signatureStatus = $signatureCase.Status; $script:signatureSubject = $signatureCase.Subject; Write-Fixture
            Assert-Rejected { Invoke-Prerequisites } 'signature|Microsoft'
            Assert-True ($script:installCount -eq 0) 'Untrusted bootstrapper was executed'
        }
    }
    Invoke-Test 'reboot-required installer success is accepted and detected afterward' {
        Reset-Fixture; $script:detected = $false; $script:installerExitCode = 3010; Write-Fixture
        $result = Invoke-Prerequisites
        Assert-True ($result.prerequisites.Count -eq 1) 'Post-install detection did not succeed'
    }
    Invoke-Test 'second invocation performs no installation' {
        Reset-Fixture; $script:detected = $false; Write-Fixture
        Invoke-Prerequisites | Out-Null; Invoke-Prerequisites | Out-Null
        Assert-True ($script:downloadCount -eq 1 -and $script:installCount -eq 1) 'Second invocation was not idempotent'
    }
    Invoke-Test 'bootstrapper receives only the approved component IDs and stable installer switches' {
        Reset-Fixture; $script:detected = $false; Write-Fixture; $script:capturedInstallerArguments = $null
        $captureInstaller = {
            param($Path, $Arguments)
            $script:installCount++; $script:detected = $true; $script:capturedInstallerArguments = @($Arguments)
            return @{ ExitCode = 0; Output = '' }
        }
        Test-ToolchainPrerequisites -CatalogPath $catalogPath -Context ci -RunnerImage windows-latest-l `
            -VsWherePath $vswherePath -VsWhereRunner $vswhereRunner -ProbeRunner $probeRunner `
            -DownloadRunner $downloadRunner -SignatureRunner $signatureRunner -InstallerRunner $captureInstaller `
            -TemporaryDirectory $root | Out-Null
        foreach ($component in $script:catalog.runnerPrerequisites[0].requiredComponents) {
            $index = [Array]::IndexOf($script:capturedInstallerArguments, $component)
            Assert-True ($index -gt 0 -and $script:capturedInstallerArguments[$index - 1] -ceq '--add') "Missing --add $component"
        }
        Assert-True ($script:capturedInstallerArguments -cnotcontains '--includeRecommended') 'Installer broadened the component set'
    }
    Invoke-Test 'wrong runner label fails before detection or download' {
        Reset-Fixture; Write-Fixture
        Assert-Rejected { Invoke-Prerequisites 'ci' 'windows-latest' } 'windows-latest-l.*windows-latest'
        Assert-True ($script:vswhereCalls.Count -eq 0 -and $script:downloadCount -eq 0) 'Wrong label caused external work'
    }
    Invoke-Test 'online CI installer rejects runner mismatch before asset synchronization' {
        Reset-Fixture; Write-Fixture
        Import-Module (Join-Path $repoRoot 'src/ToolchainInstall.psm1') -Force
        $installRoot = Join-Path $root 'installed'
        Assert-Rejected {
            Install-ToolchainProfile -CatalogPath $catalogPath -Profile ci-windows -InstallRoot $installRoot `
                -RunnerImage 'wrong-label' -GitHubCliPath (Join-Path $root 'must-not-run.cmd')
        } 'runner'
        Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'Prerequisite failure created installation files'
        Import-Module $modulePath -Force
    }
    Invoke-Test 'MinGW-only developer setup does not require Visual Studio' {
        Reset-Fixture; Write-Fixture
        $result = Invoke-Prerequisites 'developer' '' -MinGWOnly
        Assert-True ($result.prerequisites.Count -eq 0) 'Developer setup unexpectedly required Visual Studio'
        Assert-True ($script:vswhereCalls.Count -eq 0 -and $script:downloadCount -eq 0) 'Developer setup touched Visual Studio'
    }
    Invoke-Test 'full developer setup retains the Visual Studio external prerequisite' {
        Reset-Fixture; Write-Fixture
        $result = Invoke-Prerequisites 'developer' ''
        Assert-True ($result.prerequisites.Count -eq 1) 'Full developer setup skipped Visual Studio'
        Assert-True ($script:vswhereCalls.Count -eq 1 -and $script:downloadCount -eq 0) 'Existing developer Visual Studio was modified'
    }
    Invoke-Test 'Visual Studio is never a package or profile asset' {
        Reset-Fixture; Write-Fixture
        Assert-True (@($script:catalog.packages.id | Where-Object { $_ -match '(?i)visual-studio|buildtools|^msvc$' }).Count -eq 0) 'Visual Studio was packaged'
        foreach ($profile in $script:catalog.profiles.PSObject.Properties) {
            Assert-True (@($profile.Value | Where-Object { $_ -match '(?i)visual-studio|buildtools|^msvc$' }).Count -eq 0) 'Visual Studio appeared in a profile'
        }
        foreach ($forbidden in @('release', 'asset', 'sha256', 'sizeBytes', 'repository')) {
            Assert-True ($null -eq $script:catalog.runnerPrerequisites[0].PSObject.Properties[$forbidden]) "Prerequisite has forbidden package metadata '$forbidden'"
        }
    }
} finally {
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host "Prerequisite tests: $script:passed passed, $script:failed failed."
if ($script:failed -gt 0) { exit 1 }
