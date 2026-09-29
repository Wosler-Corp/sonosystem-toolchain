Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ToolchainCatalog.psm1') -Force

function Assert-PrerequisiteValue($Name, $Expected, $Observed) {
    if ([string]$Expected -cne [string]$Observed) {
        throw "Prerequisite ${Name}: expected '$Expected'; observed '$Observed'."
    }
}

function Invoke-PrerequisiteProbe {
    param([string]$Path, [string[]]$Arguments, [scriptblock]$ProbeRunner)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Prerequisite probe: expected installed file '$Path'; observed missing."
    }
    if ($ProbeRunner) { return & $ProbeRunner $Path $Arguments }
    $output = & $Path @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = [string]::Join([Environment]::NewLine, @($output)) }
}

function Test-ToolchainPrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][ValidateSet('ci', 'developer')][string]$Context,
        [string]$RunnerImage,
        [string]$OutputPath,
        [string]$VsWherePath,
        [scriptblock]$ProbeRunner
    )
    $catalog = Read-ToolchainCatalog -Path $CatalogPath
    Test-ToolchainCatalog -Catalog $catalog
    $catalogHash = (Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $requiredContext = if ($Context -ceq 'ci') { 'runner' } else { 'developer' }
    $requirements = @($catalog.runnerPrerequisites | Where-Object context -CEQ $requiredContext)
    if ($requirements.Count -eq 0) {
        throw "Prerequisite context: expected an approved '$requiredContext' product contract; observed none."
    }
    # Validate the runner identity before invoking any executable.
    if ($Context -ceq 'ci') {
        foreach ($requirement in $requirements) {
            $label = $requirement.PSObject.Properties['supportedRunnerLabel']
            if ($null -ne $label) { Assert-PrerequisiteValue 'runner label' $label.Value $RunnerImage }
        }
    }
    if (-not $VsWherePath) {
        $installerRoot = [Environment]::GetFolderPath('ProgramFilesX86')
        $VsWherePath = Join-Path $installerRoot 'Microsoft Visual Studio/Installer/vswhere.exe'
    }
    if (-not (Test-Path -LiteralPath $VsWherePath -PathType Leaf)) {
        throw "Prerequisite vswhere: expected installed Visual Studio Installer probe '$VsWherePath'; observed missing."
    }
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($requirement in $requirements) {
        $arguments = @('-latest', '-products', [string]$requirement.productId, '-version', [string]$requirement.versionFamily, '-requires') + @($requirement.requiredComponents) + @('-format', 'json', '-utf8')
        $output = & $VsWherePath @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $raw = [string]::Join([Environment]::NewLine, @($output))
        if ($exitCode -ne 0) { throw "Prerequisite vswhere: expected exit 0; observed exit $exitCode ($raw)." }
        try { $instances = @(ConvertFrom-Json -InputObject $raw -Depth 20 -ErrorAction Stop) }
        catch { throw "Prerequisite vswhere JSON: expected a valid installation array; observed '$raw'." }
        if ($instances.Count -ne 1 -or $null -eq $instances[0]) {
            throw "Prerequisite product/components: expected '$($requirement.productId)' in '$($requirement.versionFamily)' with '$($requirement.requiredComponents -join ', ')'; observed '$raw'."
        }
        $instance = $instances[0]
        foreach ($field in @('productId', 'installationVersion', 'installationPath', 'isComplete', 'isLaunchable')) {
            if ($null -eq $instance.PSObject.Properties[$field]) { throw "Prerequisite vswhere JSON: expected '$field'; observed '$raw'." }
        }
        Assert-PrerequisiteValue 'productId' $requirement.productId $instance.productId
        Assert-PrerequisiteValue 'installationVersion' $requirement.versionProbes.installationVersion $instance.installationVersion
        Assert-PrerequisiteValue 'complete installation' $true $instance.isComplete
        Assert-PrerequisiteValue 'launchable installation' $true $instance.isLaunchable
        $installation = [string]$instance.installationPath
        $toolsFile = Join-Path $installation 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
        if (-not (Test-Path -LiteralPath $toolsFile -PathType Leaf)) { throw "Prerequisite vcToolsVersion: expected '$($requirement.versionProbes.vcToolsVersion)'; observed missing '$toolsFile'." }
        $toolsVersion = (Get-Content -LiteralPath $toolsFile -Raw).Trim()
        Assert-PrerequisiteValue 'vcToolsVersion' $requirement.versionProbes.vcToolsVersion $toolsVersion
        $toolsetPattern = Join-Path $installation "MSBuild/Microsoft/VC/*/Platforms/x64/PlatformToolsets/$($requirement.toolset)/Toolset.props"
        if (@(Get-ChildItem -Path $toolsetPattern -File -ErrorAction SilentlyContinue).Count -eq 0) {
            throw "Prerequisite toolset: expected installed '$($requirement.toolset)' x64 Toolset.props; observed none."
        }
        $msbuild = Invoke-PrerequisiteProbe -Path (Join-Path $installation 'MSBuild/Current/Bin/MSBuild.exe') -Arguments @('-version', '-nologo') -ProbeRunner $ProbeRunner
        Assert-PrerequisiteValue 'MSBuild exit' 0 $msbuild.ExitCode
        Assert-PrerequisiteValue 'msbuildVersion' $requirement.versionProbes.msbuildVersion ([string]$msbuild.Output).Trim()
        $compiler = Invoke-PrerequisiteProbe -Path (Join-Path $installation "VC/Tools/MSVC/$toolsVersion/bin/Hostx64/x64/cl.exe") -Arguments @('/Bv') -ProbeRunner $ProbeRunner
        # cl /Bv without a source reports its version and may return D8003 (exit 2).
        $compilerText = [string]$compiler.Output
        if ($compiler.ExitCode -notin @(0, 2) -or $compilerText -notmatch '(?im)Compiler Version ([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?) for x64') {
            throw "Prerequisite compilerVersion: expected '$($requirement.versionProbes.compilerVersion)' for x64; observed exit $($compiler.ExitCode), '$compilerText'."
        }
        $compilerVersion = $Matches[1]
        Assert-PrerequisiteValue 'compilerVersion' $requirement.versionProbes.compilerVersion $compilerVersion
        $cmake = Invoke-PrerequisiteProbe -Path (Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe') -Arguments @('-E', 'capabilities') -ProbeRunner $ProbeRunner
        Assert-PrerequisiteValue 'CMake capabilities exit' 0 $cmake.ExitCode
        try {
            $capabilities = ConvertFrom-Json -InputObject ([string]$cmake.Output) -Depth 20
            if ($null -eq $capabilities -or $null -eq $capabilities.PSObject.Properties['generators']) { throw 'Missing generators' }
            foreach ($generator in @($capabilities.generators)) {
                if ($null -eq $generator -or $null -eq $generator.PSObject.Properties['name'] -or $null -eq $generator.PSObject.Properties['toolsetSupport']) { throw 'Malformed generator' }
            }
        }
        catch { throw "Prerequisite CMake JSON: expected generator '$($requirement.generator)'; observed '$($cmake.Output)'." }
        $generators = @($capabilities.generators | Where-Object { $_.name -ceq $requirement.generator -and $_.toolsetSupport -eq $true })
        if ($generators.Count -ne 1) { throw "Prerequisite generator: expected '$($requirement.generator)' with toolset support; observed '$($cmake.Output)'." }
        $redistFile = Join-Path $installation 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt'
        if (-not (Test-Path -LiteralPath $redistFile -PathType Leaf)) { throw "Prerequisite redist: expected installed default-version file; observed missing '$redistFile'." }
        $redistVersion = (Get-Content -LiteralPath $redistFile -Raw).Trim()
        if ($redistVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$') { throw "Prerequisite redist: expected an installed numeric version; observed '$redistVersion'." }
        $redistPayload = Join-Path $installation "VC/Redist/MSVC/$redistVersion/x64/Microsoft.VC$(([string]$requirement.toolset).Substring(1)).CRT/vcruntime140.dll"
        if (-not (Test-Path -LiteralPath $redistPayload -PathType Leaf)) { throw "Prerequisite redist: expected x64 runtime '$redistPayload'; observed missing." }
        $observations.Add([ordered]@{
            id = $requirement.id; productId = $instance.productId; installationVersion = $instance.installationVersion
            installationPath = $installation; requiredComponents = @($requirement.requiredComponents)
            generator = $requirement.generator; toolset = $requirement.toolset; vcToolsVersion = $toolsVersion
            compilerVersion = $compilerVersion; msbuildVersion = ([string]$msbuild.Output).Trim(); redistVersion = $redistVersion
        })
    }
    $result = [pscustomobject][ordered]@{ catalogSha256 = $catalogHash; context = $Context; runnerImage = $RunnerImage; prerequisites = @($observations.ToArray()) }
    if ($OutputPath) {
        $json = ConvertTo-Json -InputObject $result -Depth 20
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
    return $result
}

Export-ModuleMember -Function Test-ToolchainPrerequisites
