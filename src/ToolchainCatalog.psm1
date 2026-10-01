Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AllowedInstallKinds = @('zip', 'driver')
$script:AllowedInstallTargets = @('toolchain-root', 'msys2-root', 'vcpkg-root', 'windows-driver-store')
$script:AllowedProbeTypes = @(
    'file-exists',
    'file-version',
    'command-version',
    'sha256',
    'authenticode-valid',
    'inf-provider-version'
)

function Get-RequiredValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "$Context is missing required property '$Name'."
    }
    return $property.Value
}

function Assert-NonEmptyString {
    param(
        $Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Context must be a non-empty string."
    }
}

function Assert-PositiveInteger {
    param(
        $Value,
        [Parameter(Mandatory)][string]$Context
    )

    [long]$parsed = 0
    if (-not [long]::TryParse([string]$Value, [ref]$parsed) -or $parsed -le 0) {
        throw "$Context must be a positive integer."
    }
}

function Assert-SafeRelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Context,
        [switch]$AllowCurrentDirectory
    )

    Assert-NonEmptyString -Value $Path -Context $Context
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:') {
        throw "$Context must be relative: $Path"
    }

    $segments = @($Path -split '[\\/]')
    if ($segments -contains '..') {
        throw "$Context must not contain parent traversal: $Path"
    }
    if (-not $AllowCurrentDirectory -and $segments -contains '.') {
        throw "$Context must not contain current-directory segments: $Path"
    }
}

function New-PackageMap {
    param([Parameter(Mandatory)]$Packages)

    $packageMap = @{}
    foreach ($package in @($Packages)) {
        $id = [string](Get-RequiredValue -InputObject $package -Name 'id' -Context 'package')
        if ($packageMap.ContainsKey($id)) {
            throw "Catalog contains duplicate package ID '$id'."
        }
        $packageMap[$id] = $package
    }
    return $packageMap
}

function Resolve-PackageClosure {
    param(
        [Parameter(Mandatory)][hashtable]$PackageMap,
        [Parameter(Mandatory)][string[]]$Roots
    )

    $state = @{}
    $result = [Collections.Generic.List[object]]::new()
    $visit = $null
    $visit = {
        param([string]$PackageId)

        if (-not $PackageMap.ContainsKey($PackageId)) {
            throw "Profile references missing package '$PackageId'."
        }

        if ($state[$PackageId] -eq 'visiting') {
            throw "Catalog contains a dependency cycle involving '$PackageId'."
        }
        if ($state[$PackageId] -eq 'visited') {
            return
        }

        $state[$PackageId] = 'visiting'
        foreach ($dependency in @($PackageMap[$PackageId].dependencies)) {
            & $visit ([string]$dependency)
        }
        $state[$PackageId] = 'visited'
        $result.Add($PackageMap[$PackageId])
    }

    foreach ($root in $Roots) {
        & $visit $root
    }
    return $result.ToArray()
}

function Read-ToolchainCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Catalog file does not exist: $Path"
    }

    try {
        # ConvertFrom-Json has no -Depth parameter in Windows PowerShell 5.1.
        # Parsing does not truncate object depth, so the parameter is unnecessary.
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Catalog is not valid JSON: $Path. $($_.Exception.Message)"
    }
}

function Test-ToolchainCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)

    $schemaVersion = Get-RequiredValue -InputObject $Catalog -Name 'schemaVersion' -Context 'catalog'
    if ($schemaVersion -ne 1) {
        throw "Unsupported catalog schemaVersion '$schemaVersion'; expected 1."
    }

    $catalogId = Get-RequiredValue -InputObject $Catalog -Name 'catalogId' -Context 'catalog'
    Assert-NonEmptyString -Value $catalogId -Context 'catalogId'
    if ($catalogId -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw "catalogId contains unsupported characters: $catalogId"
    }

    $platform = Get-RequiredValue -InputObject $Catalog -Name 'platform' -Context 'catalog'
    if ($platform -ne 'windows') {
        throw "Catalog platform must be 'windows', found '$platform'."
    }
    $architecture = Get-RequiredValue -InputObject $Catalog -Name 'architecture' -Context 'catalog'
    if ($architecture -ne 'x86_64') {
        throw "Catalog architecture must be 'x86_64', found '$architecture'."
    }

    $packages = @(Get-RequiredValue -InputObject $Catalog -Name 'packages' -Context 'catalog')
    if ($packages.Count -eq 0) {
        throw 'Catalog packages must not be empty.'
    }
    $packageMap = New-PackageMap -Packages $packages

    $prerequisites = @(Get-RequiredValue -InputObject $Catalog -Name 'runnerPrerequisites' -Context 'catalog')
    if ($prerequisites.Count -eq 0) { throw 'Catalog runnerPrerequisites must not be empty.' }
    $prerequisiteIds = @{}
    foreach ($prerequisite in $prerequisites) {
        $id = [string](Get-RequiredValue -InputObject $prerequisite -Name 'id' -Context 'runner prerequisite')
        if ($id -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { throw "Runner prerequisite ID is invalid: $id" }
        if ($prerequisiteIds.ContainsKey($id) -or $packageMap.ContainsKey($id)) {
            throw "Catalog contains duplicate runner prerequisite or package ID '$id'."
        }
        $prerequisiteIds[$id] = $true
        $allowed = @('id', 'platform', 'context', 'productSelection', 'requiredComponents', 'generator', 'toolset', 'versionFamily', 'detection', 'bootstrap', 'supportedRunnerLabel')
        foreach ($property in $prerequisite.PSObject.Properties) {
            if ($property.Name -cnotin $allowed) { throw "Runner prerequisite '$id' has unsupported property '$($property.Name)'." }
        }
        if ((Get-RequiredValue -InputObject $prerequisite -Name 'platform' -Context "runner prerequisite '$id'") -cne 'windows') {
            throw "Runner prerequisite '$id' platform must be windows."
        }
        if ((Get-RequiredValue -InputObject $prerequisite -Name 'context' -Context "runner prerequisite '$id'") -cnotin @('runner', 'developer')) {
            throw "Runner prerequisite '$id' context is unsupported."
        }
        if ([string](Get-RequiredValue -InputObject $prerequisite -Name 'productSelection' -Context "runner prerequisite '$id'") -cne '*') {
            throw "Runner prerequisite '$id' productSelection must accept all Visual Studio products."
        }
        $components = @(Get-RequiredValue -InputObject $prerequisite -Name 'requiredComponents' -Context "runner prerequisite '$id'")
        if ($components.Count -eq 0) { throw "Runner prerequisite '$id' requires component IDs." }
        $componentIds = @{}
        foreach ($component in $components) {
            if ([string]$component -cnotmatch '^Microsoft\.[A-Za-z0-9.]+$' -or $componentIds.ContainsKey([string]$component)) {
                throw "Runner prerequisite '$id' has invalid or duplicate component '$component'."
            }
            $componentIds[[string]$component] = $true
        }
        $requiredVisualStudioComponents = @(
            'Microsoft.Component.MSBuild',
            'Microsoft.VisualStudio.Component.VC.CMake.Project',
            'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
            'Microsoft.VisualStudio.Component.VC.Redist.14.Latest'
        )
        if ($components.Count -ne $requiredVisualStudioComponents.Count -or @($requiredVisualStudioComponents | Where-Object { $_ -cnotin $components }).Count -ne 0) {
            throw "Runner prerequisite '$id' component contract is incomplete or unsupported."
        }
        if ([string](Get-RequiredValue -InputObject $prerequisite -Name 'generator' -Context "runner prerequisite '$id'") -cne 'Visual Studio 17 2022') {
            throw "Runner prerequisite '$id' generator must be Visual Studio 17 2022."
        }
        if ([string](Get-RequiredValue -InputObject $prerequisite -Name 'toolset' -Context "runner prerequisite '$id'") -cne 'v143') {
            throw "Runner prerequisite '$id' toolset must be v143."
        }
        if ([string](Get-RequiredValue -InputObject $prerequisite -Name 'versionFamily' -Context "runner prerequisite '$id'") -cne '[17.0,18.0)') {
            throw "Runner prerequisite '$id' versionFamily must be [17.0,18.0)."
        }
        $detection = Get-RequiredValue -InputObject $prerequisite -Name 'detection' -Context "runner prerequisite '$id'"
        foreach ($property in $detection.PSObject.Properties) {
            if ($property.Name -cnotin @('requiresComplete', 'requiresLaunchable')) { throw "Runner prerequisite '$id' detection has unsupported property '$($property.Name)'." }
        }
        if ((Get-RequiredValue -InputObject $detection -Name 'requiresComplete' -Context "runner prerequisite '$id' detection") -ne $true -or
            (Get-RequiredValue -InputObject $detection -Name 'requiresLaunchable' -Context "runner prerequisite '$id' detection") -ne $true) {
            throw "Runner prerequisite '$id' detection must require complete and launchable installations."
        }
        $bootstrap = Get-RequiredValue -InputObject $prerequisite -Name 'bootstrap' -Context "runner prerequisite '$id'"
        foreach ($property in $bootstrap.PSObject.Properties) {
            if ($property.Name -cnotin @('url', 'signerOrganization', 'arguments', 'successExitCodes', 'temporary')) { throw "Runner prerequisite '$id' bootstrap has unsupported property '$($property.Name)'." }
        }
        if ([string](Get-RequiredValue -InputObject $bootstrap -Name 'url' -Context "runner prerequisite '$id' bootstrap") -cne 'https://aka.ms/vs/17/release/vs_BuildTools.exe') {
            throw "Runner prerequisite '$id' bootstrap url must be the official Visual Studio 2022 service."
        }
        if ([string](Get-RequiredValue -InputObject $bootstrap -Name 'signerOrganization' -Context "runner prerequisite '$id' bootstrap") -cne 'Microsoft Corporation') {
            throw "Runner prerequisite '$id' bootstrap signer must be Microsoft Corporation."
        }
        if ([string]::Join('|', @($bootstrap.arguments)) -cne '--quiet|--wait|--norestart|--nocache') {
            throw "Runner prerequisite '$id' bootstrap arguments are unsupported."
        }
        if ([string]::Join('|', @($bootstrap.successExitCodes)) -cne '0|1641|3010') {
            throw "Runner prerequisite '$id' bootstrap success exit codes are unsupported."
        }
        if ((Get-RequiredValue -InputObject $bootstrap -Name 'temporary' -Context "runner prerequisite '$id' bootstrap") -ne $true) {
            throw "Runner prerequisite '$id' bootstrap must be temporary."
        }
        $label = $prerequisite.PSObject.Properties['supportedRunnerLabel']
        if ($null -ne $label -and [string]$label.Value -cne 'windows-latest-l') {
            throw "Runner prerequisite '$id' supportedRunnerLabel is unsupported."
        }
    }

    foreach ($package in $packages) {
        $id = [string](Get-RequiredValue -InputObject $package -Name 'id' -Context 'package')
        if ($id -notmatch '^[a-z0-9][a-z0-9._-]*$') {
            throw "Package ID contains unsupported characters: $id"
        }

        $version = [string](Get-RequiredValue -InputObject $package -Name 'version' -Context "package '$id'")
        if ($version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
            throw "Package '$id' version must be exact semantic version, found '$version'."
        }

        $release = Get-RequiredValue -InputObject $package -Name 'release' -Context "package '$id'"
        $repository = [string](Get-RequiredValue -InputObject $release -Name 'repository' -Context "package '$id' release")
        if ($repository -cne 'Wosler-Corp/sonosystem-toolchain') {
            throw "Package '$id' release repository must be Wosler-Corp/sonosystem-toolchain."
        }
        $tag = [string](Get-RequiredValue -InputObject $release -Name 'tag' -Context "package '$id' release")
        Assert-NonEmptyString -Value $tag -Context "package '$id' release tag"
        if ($tag -match '(?i)^latest$') {
            throw "Package '$id' release tag must not be floating."
        }
        $asset = [string](Get-RequiredValue -InputObject $release -Name 'asset' -Context "package '$id' release")
        Assert-SafeRelativePath -Path $asset -Context "package '$id' release asset"
        if ($asset -match '[\\/]') {
            throw "Package '$id' release asset must be a filename: $asset"
        }
        $sha256 = [string](Get-RequiredValue -InputObject $release -Name 'sha256' -Context "package '$id' release")
        if ($sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Package '$id' release sha256 must contain 64 lowercase hexadecimal characters."
        }
        Assert-PositiveInteger -Value (Get-RequiredValue -InputObject $release -Name 'sizeBytes' -Context "package '$id' release") `
            -Context "package '$id' release sizeBytes"
        $attestation = [string](Get-RequiredValue -InputObject $release -Name 'attestation' -Context "package '$id' release")
        if ($attestation -cne 'github-immutable-release') {
            throw "Package '$id' release attestation must be 'github-immutable-release'."
        }

        $upstream = Get-RequiredValue -InputObject $package -Name 'upstream' -Context "package '$id'"
        $upstreamUrl = [string](Get-RequiredValue -InputObject $upstream -Name 'url' -Context "package '$id' upstream")
        [uri]$parsedUri = $null
        if (-not [uri]::TryCreate($upstreamUrl, [UriKind]::Absolute, [ref]$parsedUri) -or `
            $parsedUri.Scheme -notin @('https', 'http')) {
            throw "Package '$id' upstream url must be an absolute HTTP(S) URI."
        }
        Assert-NonEmptyString -Value (Get-RequiredValue -InputObject $upstream -Name 'version' -Context "package '$id' upstream") `
            -Context "package '$id' upstream version"
        $retrievedAt = [string](Get-RequiredValue -InputObject $upstream -Name 'retrievedAt' -Context "package '$id' upstream")
        [datetimeoffset]$retrievedTimestamp = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($retrievedAt, [ref]$retrievedTimestamp)) {
            throw "Package '$id' upstream retrievedAt is not a timestamp."
        }

        $licenses = @(Get-RequiredValue -InputObject $package -Name 'licenses' -Context "package '$id'")
        if ($licenses.Count -eq 0) {
            throw "Package '$id' license metadata must not be empty."
        }
        foreach ($licensePath in $licenses) {
            Assert-SafeRelativePath -Path ([string]$licensePath) -Context "package '$id' license path"
            if ([string]$licensePath -cnotmatch '^licenses[\\/]') {
                throw "Package '$id' license path must be under licenses/: $licensePath"
            }
        }

        $dependencies = @(Get-RequiredValue -InputObject $package -Name 'dependencies' -Context "package '$id'")
        $seenDependencies = @{}
        foreach ($dependency in $dependencies) {
            $dependencyId = [string]$dependency
            Assert-NonEmptyString -Value $dependencyId -Context "package '$id' dependency"
            if (-not $packageMap.ContainsKey($dependencyId)) {
                throw "Package '$id' references missing dependency '$dependencyId'."
            }
            if ($seenDependencies.ContainsKey($dependencyId)) {
                throw "Package '$id' contains duplicate dependency '$dependencyId'."
            }
            $seenDependencies[$dependencyId] = $true
        }

        $install = Get-RequiredValue -InputObject $package -Name 'install' -Context "package '$id'"
        Assert-PositiveInteger -Value (Get-RequiredValue -InputObject $install -Name 'recipeVersion' -Context "package '$id' install") `
            -Context "package '$id' install recipeVersion"
        $kind = [string](Get-RequiredValue -InputObject $install -Name 'kind' -Context "package '$id' install")
        if ($kind -cnotin $script:AllowedInstallKinds) {
            throw "Package '$id' install kind '$kind' is unsupported."
        }
        $target = [string](Get-RequiredValue -InputObject $install -Name 'target' -Context "package '$id' install")
        if ($target -cnotin $script:AllowedInstallTargets) {
            throw "Package '$id' install target '$target' is unsupported."
        }
        $destination = [string](Get-RequiredValue -InputObject $install -Name 'destination' -Context "package '$id' install")
        Assert-SafeRelativePath -Path $destination -Context "package '$id' install destination" -AllowCurrentDirectory
        Assert-PositiveInteger -Value (Get-RequiredValue -InputObject $install -Name 'expandedSizeBytes' -Context "package '$id' install") `
            -Context "package '$id' install expandedSizeBytes"

        $validation = @(Get-RequiredValue -InputObject $package -Name 'validation' -Context "package '$id'")
        if ($validation.Count -eq 0) {
            throw "Package '$id' validation probes must not be empty."
        }
        foreach ($probe in $validation) {
            $probeType = [string](Get-RequiredValue -InputObject $probe -Name 'type' -Context "package '$id' validation probe")
            if ($probeType -cnotin $script:AllowedProbeTypes) {
                throw "Package '$id' validation probe type '$probeType' is unsupported."
            }
            $probePath = [string](Get-RequiredValue -InputObject $probe -Name 'path' -Context "package '$id' validation probe")
            Assert-SafeRelativePath -Path $probePath -Context "package '$id' validation path" -AllowCurrentDirectory
        }
    }

    foreach ($packageId in $packageMap.Keys) {
        [void](Resolve-PackageClosure -PackageMap $packageMap -Roots @($packageId))
    }

    $profiles = Get-RequiredValue -InputObject $Catalog -Name 'profiles' -Context 'catalog'
    foreach ($requiredProfile in @('ci-windows', 'dev-windows')) {
        if ($null -eq $profiles.PSObject.Properties[$requiredProfile]) {
            throw "Catalog profiles are missing '$requiredProfile'."
        }
    }

    foreach ($profileProperty in @($profiles.PSObject.Properties)) {
        $roots = @($profileProperty.Value)
        if ($roots.Count -eq 0) {
            throw "Profile '$($profileProperty.Name)' must not be empty."
        }
        $seenRoots = @{}
        foreach ($root in $roots) {
            $rootId = [string]$root
            if (-not $packageMap.ContainsKey($rootId)) {
                throw "Profile '$($profileProperty.Name)' references missing package '$rootId'."
            }
            if ($seenRoots.ContainsKey($rootId)) {
                throw "Profile '$($profileProperty.Name)' contains duplicate package '$rootId'."
            }
            $seenRoots[$rootId] = $true
        }
        [void](Resolve-PackageClosure -PackageMap $packageMap -Roots ([string[]]$roots))
    }

    $ciIds = @((Resolve-PackageClosure -PackageMap $packageMap -Roots ([string[]]@($profiles.'ci-windows'))).id)
    $devIds = @((Resolve-PackageClosure -PackageMap $packageMap -Roots ([string[]]@($profiles.'dev-windows'))).id)
    foreach ($ciId in $ciIds) {
        if ([string]$packageMap[$ciId].install.kind -ceq 'driver') {
            throw "ci-windows profile cannot contain driver package '$ciId'."
        }
    }
    foreach ($ciId in $ciIds) {
        if ($ciId -cnotin $devIds) {
            throw "dev-windows profile must contain the ci-windows closure; missing '$ciId'."
        }
    }
}

function Resolve-ToolchainProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Profile
    )

    Test-ToolchainCatalog -Catalog $Catalog
    $profileProperty = $Catalog.profiles.PSObject.Properties[$Profile]
    if ($null -eq $profileProperty) {
        throw "Catalog does not define profile '$Profile'."
    }

    $packageMap = New-PackageMap -Packages @($Catalog.packages)
    return Resolve-PackageClosure -PackageMap $packageMap -Roots ([string[]]@($profileProperty.Value))
}

Export-ModuleMember -Function Read-ToolchainCatalog, Test-ToolchainCatalog, Resolve-ToolchainProfile
