Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ToolchainCatalog.psm1') -Force

function Assert-PrerequisiteValue($Name, $Expected, $Observed) {
    if ([string]$Expected -cne [string]$Observed) {
        throw "Prerequisite ${Name}: expected '$Expected'; observed '$Observed'."
    }
}

function Write-PrerequisiteEvidence($Result, [string]$OutputPath) {
    if (-not $OutputPath) { return }
    $json = ConvertTo-Json -InputObject $Result -Depth 20
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
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

function Invoke-VsWhereQuery {
    param($Requirement, [string]$VsWherePath, [scriptblock]$VsWhereRunner)
    $arguments = @('-latest', '-products', '*', '-version', [string]$Requirement.versionFamily, '-requires') +
        @($Requirement.requiredComponents) + @('-format', 'json', '-utf8')
    if ($VsWhereRunner) {
        $query = & $VsWhereRunner $VsWherePath $arguments
    } elseif (-not (Test-Path -LiteralPath $VsWherePath -PathType Leaf)) {
        return $null
    } else {
        $output = & $VsWherePath @arguments 2>&1
        $query = @{ ExitCode = $LASTEXITCODE; Output = [string]::Join([Environment]::NewLine, @($output)) }
    }
    if ([int]$query.ExitCode -ne 0) {
        throw "Prerequisite vswhere: expected exit 0; observed exit $($query.ExitCode) ($($query.Output))."
    }
    $raw = [string]$query.Output
    try { $instances = @(ConvertFrom-Json -InputObject $raw -Depth 20 -ErrorAction Stop) }
    catch { throw "Prerequisite vswhere JSON: expected a valid installation array; observed '$raw'." }
    if ($instances.Count -eq 0 -or $null -eq $instances[0]) { return $null }
    if ($instances.Count -ne 1) { throw "Prerequisite vswhere: expected one latest matching installation; observed '$raw'." }
    return $instances[0]
}

function Install-VisualStudioPrerequisite {
    param(
        $Requirement,
        [string]$TemporaryDirectory,
        [scriptblock]$DownloadRunner,
        [scriptblock]$SignatureRunner,
        [scriptblock]$InstallerRunner
    )
    if (-not $TemporaryDirectory) { $TemporaryDirectory = [IO.Path]::GetTempPath() }
    $temporaryRoot = Join-Path ([IO.Path]::GetFullPath($TemporaryDirectory)) "Wosler-vs-$([guid]::NewGuid().ToString('N'))"
    $bootstrapper = Join-Path $temporaryRoot 'vs_BuildTools.exe'
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    try {
        if ($DownloadRunner) {
            & $DownloadRunner ([string]$Requirement.bootstrap.url) $bootstrapper
        } else {
            Invoke-WebRequest -Uri ([string]$Requirement.bootstrap.url) -OutFile $bootstrapper -UseBasicParsing
        }
        if (-not (Test-Path -LiteralPath $bootstrapper -PathType Leaf)) {
            throw "Prerequisite bootstrap download: expected '$bootstrapper'; observed missing."
        }
        if ($SignatureRunner) {
            $signature = & $SignatureRunner $bootstrapper
        } else {
            $authenticode = Get-AuthenticodeSignature -LiteralPath $bootstrapper
            $signature = @{
                Status = [string]$authenticode.Status
                SignerSubject = if ($authenticode.SignerCertificate) { [string]$authenticode.SignerCertificate.Subject } else { '' }
            }
        }
        $status = [string]$signature.Status
        $subject = [string]$signature.SignerSubject
        $expectedOrganization = [regex]::Escape([string]$Requirement.bootstrap.signerOrganization)
        if ($status -cne 'Valid' -or $subject -notmatch "(?i)(?:^|,\s*)(?:CN|O)=$expectedOrganization(?:,|$)") {
            throw "Prerequisite bootstrap signature: expected Valid Microsoft signature; observed status '$status', signer '$subject'."
        }
        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in @($Requirement.bootstrap.arguments)) { $arguments.Add([string]$argument) }
        foreach ($component in @($Requirement.requiredComponents)) {
            $arguments.Add('--add')
            $arguments.Add([string]$component)
        }
        if ($InstallerRunner) {
            $installation = & $InstallerRunner $bootstrapper $arguments.ToArray()
        } else {
            $process = Start-Process -FilePath $bootstrapper -ArgumentList $arguments.ToArray() -Wait -PassThru -WindowStyle Hidden
            $installation = @{ ExitCode = $process.ExitCode; Output = '' }
        }
        if ([int]$installation.ExitCode -notin @($Requirement.bootstrap.successExitCodes | ForEach-Object { [int]$_ })) {
            throw "Prerequisite bootstrap installation: expected success or reboot-required success; observed exit $($installation.ExitCode) ($($installation.Output))."
        }
    } finally {
        if (Test-Path -LiteralPath $bootstrapper) { Remove-Item -LiteralPath $bootstrapper -Force }
        if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
    }
}

function Get-VisualStudioObservation {
    param($Requirement, $Instance, [scriptblock]$ProbeRunner)
    foreach ($field in @('productId', 'installationVersion', 'installationPath', 'isComplete', 'isLaunchable')) {
        if ($null -eq $Instance.PSObject.Properties[$field]) {
            throw "Prerequisite vswhere JSON: expected '$field'; observed incomplete installation record."
        }
    }
    if ([string]$Instance.productId -cnotmatch '^Microsoft\.VisualStudio\.Product\.[A-Za-z][A-Za-z0-9]*$') {
        throw "Prerequisite product: expected a Visual Studio product; observed '$($Instance.productId)'."
    }
    [version]$installationVersion = [version]'0.0'
    if (-not [version]::TryParse([string]$Instance.installationVersion, [ref]$installationVersion) -or
        $installationVersion -lt [version]'17.0' -or $installationVersion -ge [version]'18.0') {
        throw "Prerequisite installationVersion: expected '$($Requirement.versionFamily)'; observed '$($Instance.installationVersion)'."
    }
    Assert-PrerequisiteValue 'complete installation' $Requirement.detection.requiresComplete $Instance.isComplete
    Assert-PrerequisiteValue 'launchable installation' $Requirement.detection.requiresLaunchable $Instance.isLaunchable

    $installation = [string]$Instance.installationPath
    $toolsFile = Join-Path $installation 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
    if (-not (Test-Path -LiteralPath $toolsFile -PathType Leaf)) { throw "Prerequisite vcToolsVersion: expected installed default-version file; observed missing '$toolsFile'." }
    $toolsVersion = (Get-Content -LiteralPath $toolsFile -Raw).Trim()
    if ($toolsVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$') { throw "Prerequisite vcToolsVersion: expected a numeric observed value; observed '$toolsVersion'." }

    $toolsetPattern = Join-Path $installation "MSBuild/Microsoft/VC/*/Platforms/x64/PlatformToolsets/$($Requirement.toolset)/Toolset.props"
    if (@(Get-ChildItem -Path $toolsetPattern -File -ErrorAction SilentlyContinue).Count -eq 0) {
        throw "Prerequisite toolset: expected installed '$($Requirement.toolset)' x64 Toolset.props; observed none."
    }
    $msbuild = Invoke-PrerequisiteProbe -Path (Join-Path $installation 'MSBuild/Current/Bin/MSBuild.exe') -Arguments @('-version', '-nologo') -ProbeRunner $ProbeRunner
    Assert-PrerequisiteValue 'MSBuild exit' 0 $msbuild.ExitCode
    $msbuildVersion = ([string]$msbuild.Output).Trim()
    if ($msbuildVersion -cnotmatch '[0-9]+\.[0-9]+') { throw "Prerequisite msbuildVersion: expected a numeric observed value; observed '$msbuildVersion'." }

    $compiler = Invoke-PrerequisiteProbe -Path (Join-Path $installation "VC/Tools/MSVC/$toolsVersion/bin/Hostx64/x64/cl.exe") -Arguments @('/Bv') -ProbeRunner $ProbeRunner
    $compilerOutput = [string]$compiler.Output
    if ([int]$compiler.ExitCode -notin @(0, 2) -or $compilerOutput -notmatch '(?im)Compiler Version ([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?) for x64') {
        throw "Prerequisite compilerVersion: expected an x64 cl.exe /Bv result; observed exit $($compiler.ExitCode), '$compilerOutput'."
    }
    $compilerVersion = $Matches[1]

    $cmake = Invoke-PrerequisiteProbe -Path (Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe') -Arguments @('-E', 'capabilities') -ProbeRunner $ProbeRunner
    Assert-PrerequisiteValue 'CMake capabilities exit' 0 $cmake.ExitCode
    try {
        $capabilities = ConvertFrom-Json -InputObject ([string]$cmake.Output) -Depth 20
        $generators = @($capabilities.generators | Where-Object { $_.name -ceq $Requirement.generator -and $_.toolsetSupport -eq $true })
    } catch { throw "Prerequisite CMake JSON: expected generator '$($Requirement.generator)'; observed '$($cmake.Output)'." }
    if ($generators.Count -ne 1) { throw "Prerequisite generator: expected '$($Requirement.generator)' with toolset support; observed '$($cmake.Output)'." }

    $redistFile = Join-Path $installation 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt'
    if (-not (Test-Path -LiteralPath $redistFile -PathType Leaf)) { throw "Prerequisite redist: expected installed default-version file; observed missing '$redistFile'." }
    $redistVersion = (Get-Content -LiteralPath $redistFile -Raw).Trim()
    if ($redistVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$') { throw "Prerequisite redist: expected an installed numeric version; observed '$redistVersion'." }
    $redistPayload = Join-Path $installation "VC/Redist/MSVC/$redistVersion/x64/Microsoft.VC$(([string]$Requirement.toolset).Substring(1)).CRT/vcruntime140.dll"
    if (-not (Test-Path -LiteralPath $redistPayload -PathType Leaf)) { throw "Prerequisite redist: expected x64 runtime '$redistPayload'; observed missing." }

    $vsDevCmd = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf)) { throw "Prerequisite Windows SDK: expected '$vsDevCmd'; observed missing." }
    $commandProcessor = [Environment]::GetEnvironmentVariable('ComSpec')
    $sdkProbe = Invoke-PrerequisiteProbe -Path $commandProcessor -Arguments @('/d', '/s', '/v:on', '/c', "`"$vsDevCmd`" -no_logo -arch=x64 -host_arch=x64 >nul && echo !WindowsSDKVersion!") -ProbeRunner $ProbeRunner
    Assert-PrerequisiteValue 'Windows SDK probe exit' 0 $sdkProbe.ExitCode
    $windowsSdkVersion = ([string]$sdkProbe.Output).Trim().TrimEnd('\')
    if ($windowsSdkVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') { throw "Prerequisite Windows SDK: expected a selected numeric SDK version; observed '$windowsSdkVersion'." }

    return [ordered]@{
        id = $Requirement.id
        productId = [string]$Instance.productId
        installationVersion = [string]$Instance.installationVersion
        installationPath = $installation
        requiredComponents = @($Requirement.requiredComponents)
        generator = [string]$Requirement.generator
        toolset = [string]$Requirement.toolset
        vcToolsVersion = $toolsVersion
        compilerVersion = $compilerVersion
        compilerOutput = $compilerOutput
        msbuildVersion = $msbuildVersion
        redistVersion = $redistVersion
        windowsSdkVersion = $windowsSdkVersion
    }
}

function Test-ToolchainPrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][ValidateSet('ci', 'developer')][string]$Context,
        [string]$RunnerImage,
        [string]$OutputPath,
        [string]$VsWherePath,
        [scriptblock]$VsWhereRunner,
        [scriptblock]$ProbeRunner,
        [scriptblock]$DownloadRunner,
        [scriptblock]$SignatureRunner,
        [scriptblock]$InstallerRunner,
        [string]$TemporaryDirectory,
        [switch]$MinGWOnly
    )
    $catalog = Read-ToolchainCatalog -Path $CatalogPath
    Test-ToolchainCatalog -Catalog $catalog
    $catalogHash = (Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $requiredContext = 'runner'
    if ($Context -ceq 'developer' -and $MinGWOnly) {
        $result = [pscustomobject][ordered]@{ catalogSha256 = $catalogHash; context = $Context; runnerImage = $RunnerImage; minGWOnly = $true; prerequisites = @() }
        Write-PrerequisiteEvidence -Result $result -OutputPath $OutputPath
        return $result
    }
    $requirements = @($catalog.runnerPrerequisites | Where-Object context -CEQ $requiredContext)
    if ($requirements.Count -eq 0) {
        return [pscustomobject][ordered]@{ catalogSha256 = $catalogHash; context = $Context; runnerImage = $RunnerImage; prerequisites = @() }
    }
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
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($requirement in $requirements) {
        $instance = Invoke-VsWhereQuery -Requirement $requirement -VsWherePath $VsWherePath -VsWhereRunner $VsWhereRunner
        if ($null -eq $instance) {
            Install-VisualStudioPrerequisite -Requirement $requirement -TemporaryDirectory $TemporaryDirectory `
                -DownloadRunner $DownloadRunner -SignatureRunner $SignatureRunner -InstallerRunner $InstallerRunner
            $instance = Invoke-VsWhereQuery -Requirement $requirement -VsWherePath $VsWherePath -VsWhereRunner $VsWhereRunner
            if ($null -eq $instance) {
                throw "Prerequisite Visual Studio 2022: expected required components after installation; observed still unavailable."
            }
        }
        $observations.Add((Get-VisualStudioObservation -Requirement $requirement -Instance $instance -ProbeRunner $ProbeRunner))
    }
    $result = [pscustomobject][ordered]@{ catalogSha256 = $catalogHash; context = $Context; runnerImage = $RunnerImage; prerequisites = @($observations.ToArray()) }
    Write-PrerequisiteEvidence -Result $result -OutputPath $OutputPath
    return $result
}

Export-ModuleMember -Function Test-ToolchainPrerequisites
