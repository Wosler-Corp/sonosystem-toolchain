Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$catalogModulePath = Join-Path $PSScriptRoot 'ToolchainCatalog.psm1'
Import-Module $catalogModulePath -Force

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-InstallTargetRoot {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    switch -CaseSensitive ($Target) {
        'toolchain-root' { return $InstallRoot }
        'msys2-root' { return (Join-Path $InstallRoot 'msys64') }
        'vcpkg-root' { return (Join-Path $InstallRoot 'vcpkg') }
        'windows-driver-store' { return (Join-Path $InstallRoot 'drivers') }
        default { throw "Unsupported install target '$Target'." }
    }
}

function Get-PackageDestination {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $targetRoot = Get-InstallTargetRoot -Target ([string]$Package.install.target) -InstallRoot $InstallRoot
    $destination = [IO.Path]::GetFullPath((Join-Path $targetRoot ([string]$Package.install.destination)))
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($destination -eq $root) {
        throw "Package '$($Package.id)' cannot replace the toolchain root directly."
    }
    if (-not $destination.StartsWith("$root$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package '$($Package.id)' destination escapes the install root."
    }
    return $destination
}

function Read-InstalledState {
    param([Parameter(Mandatory)][string]$StatePath)

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -Depth 100
    } catch {
        throw "Installed toolchain state is invalid: $StatePath. $($_.Exception.Message)"
    }
}

function Get-StatePackage {
    param(
        $State,
        [Parameter(Mandatory)][string]$Id
    )

    if ($null -eq $State -or $null -eq $State.PSObject.Properties['packages']) {
        return $null
    }
    $matches = @($State.packages | Where-Object { [string]$_.id -ceq $Id } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Compare-SemanticVersion {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $pattern = '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<pre>[0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$'
    $leftMatch = [regex]::Match($Left, $pattern)
    $rightMatch = [regex]::Match($Right, $pattern)
    if (-not $leftMatch.Success -or -not $rightMatch.Success) {
        throw "Cannot compare non-semantic versions '$Left' and '$Right'."
    }
    foreach ($part in @('major', 'minor', 'patch')) {
        $comparison = [long]$leftMatch.Groups[$part].Value - [long]$rightMatch.Groups[$part].Value
        if ($comparison -lt 0) { return -1 }
        if ($comparison -gt 0) { return 1 }
    }

    $leftPre = $leftMatch.Groups['pre'].Value
    $rightPre = $rightMatch.Groups['pre'].Value
    if (-not $leftPre -and -not $rightPre) { return 0 }
    if (-not $leftPre) { return 1 }
    if (-not $rightPre) { return -1 }

    $leftParts = @($leftPre -split '\.')
    $rightParts = @($rightPre -split '\.')
    for ($index = 0; $index -lt [Math]::Max($leftParts.Count, $rightParts.Count); $index++) {
        if ($index -ge $leftParts.Count) { return -1 }
        if ($index -ge $rightParts.Count) { return 1 }
        $leftNumber = 0L
        $rightNumber = 0L
        $leftNumeric = [long]::TryParse($leftParts[$index], [ref]$leftNumber)
        $rightNumeric = [long]::TryParse($rightParts[$index], [ref]$rightNumber)
        if ($leftNumeric -and $rightNumeric) {
            if ($leftNumber -lt $rightNumber) { return -1 }
            if ($leftNumber -gt $rightNumber) { return 1 }
        } elseif ($leftNumeric -ne $rightNumeric) {
            if ($leftNumeric) { return -1 }
            return 1
        } else {
            $comparison = [string]::CompareOrdinal($leftParts[$index], $rightParts[$index])
            if ($comparison -lt 0) { return -1 }
            if ($comparison -gt 0) { return 1 }
        }
    }
    return 0
}

function Assert-OfflineAssetSet {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$OfflineAssetRoot
    )

    if (-not (Test-Path -LiteralPath $OfflineAssetRoot -PathType Container)) {
        throw "Offline asset root does not exist: $OfflineAssetRoot"
    }
    $allowed = @{}
    foreach ($package in @($Catalog.packages)) {
        $allowed[[string]$package.release.asset] = $true
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $OfflineAssetRoot -File -Recurse)) {
        if (-not $allowed.ContainsKey($file.Name)) {
            throw "Offline asset '$($file.Name)' is unexpected and not listed in the catalog."
        }
        if ($file.DirectoryName -cne ([IO.Path]::GetFullPath($OfflineAssetRoot).TrimEnd('\', '/'))) {
            throw "Offline asset '$($file.FullName)' must be stored directly under the offline asset root."
        }
    }
}

function Invoke-GitHubAssetDownload {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [Parameter(Mandatory)][string]$GitHubCliPath
    )

    $tag = [string]$Package.release.tag
    $asset = [string]$Package.release.asset
    $repository = [string]$Package.release.repository
    $downloadArguments = @('release', 'download', $tag, '--repo', $repository, '--pattern', $asset, '--dir', $DestinationDirectory, '--clobber')
    Invoke-WoslerReleaseOperation -GitHubCliPath $GitHubCliPath -Arguments $downloadArguments -Description "download '$asset'"
    $assetPath = Join-Path $DestinationDirectory $asset
    Invoke-WoslerReleaseOperation -GitHubCliPath $GitHubCliPath -Arguments @('release', 'verify-asset', $tag, $assetPath, '--repo', $repository) -Description "attestation verification '$asset'"
    return $assetPath
}

function Invoke-WoslerReleaseOperation {
    param([string]$GitHubCliPath, [string[]]$Arguments, [string]$Description)
    # Retry only classified HTTP responses from the catalog's Wosler release.
    $repositoryIndex = [Array]::IndexOf($Arguments, '--repo')
    if ($repositoryIndex -lt 0 -or $Arguments[$repositoryIndex + 1] -cne 'Wosler-Corp/sonosystem-toolchain') {
        throw 'Release access must target Wosler-Corp/sonosystem-toolchain.'
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $output = & $GitHubCliPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $message = [string]::Join([Environment]::NewLine, @($output))
        if ($exitCode -eq 0) { return }
        if ($attempt -eq 3 -or $message -notmatch '(?i)\bHTTP(?:/[0-9.]+)?\s+(408|429|5[0-9]{2})\b') {
            throw "Wosler release $Description failed (exit $exitCode): $message"
        }
        Start-Sleep -Seconds $attempt
    }
}

function Sync-ToolchainAssets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$AssetCacheRoot,
        [string]$GitHubCliPath = 'gh'
    )
    $catalog = Read-ToolchainCatalog -Path $CatalogPath
    $packages = @(Resolve-ToolchainProfile -Catalog $catalog -Profile $Profile)
    $assetNames = @{}
    foreach ($package in $packages) {
        $name = [string]$package.release.asset
        if ($assetNames.ContainsKey($name)) { throw "Duplicate flat asset filename '$name' in profile '$Profile'." }
        $assetNames[$name] = $true
    }
    $catalogHash = (Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $AssetCacheRoot = [IO.Path]::GetFullPath($AssetCacheRoot)
    $assetRoot = Join-Path $AssetCacheRoot $catalogHash
    [IO.Directory]::CreateDirectory($assetRoot) | Out-Null
    Assert-OfflineAssetSet -Catalog $catalog -OfflineAssetRoot $assetRoot
    $assets = [Collections.Generic.List[object]]::new()
    $hits = [Collections.Generic.List[string]]::new()
    $downloads = [Collections.Generic.List[string]]::new()
    $replaced = [Collections.Generic.List[string]]::new()
    foreach ($package in $packages) {
        $assetPath = Join-Path $assetRoot ([string]$package.release.asset)
        $exists = Test-Path -LiteralPath $assetPath -PathType Leaf
        $valid = $false
        if ($exists) {
            $valid = (Get-Item -LiteralPath $assetPath).Length -eq [long]$package.release.sizeBytes -and
                (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$package.release.sha256
        }
        if ($valid) {
            Invoke-WoslerReleaseOperation -GitHubCliPath $GitHubCliPath -Arguments @('release', 'verify-asset', [string]$package.release.tag, $assetPath, '--repo', [string]$package.release.repository) -Description "attestation verification '$($package.release.asset)'"
            $hits.Add([string]$package.id)
        } else {
            # Sibling staging stays on the same volume for atomic replacement and
            # never makes incomplete bytes visible in the flat installer directory.
            $staging = Join-Path $AssetCacheRoot ".download-$catalogHash-$([guid]::NewGuid().ToString('N'))"
            [IO.Directory]::CreateDirectory($staging) | Out-Null
            try {
                $verified = Get-VerifiedAsset -Package $package -OperationRoot $staging -GitHubCliPath $GitHubCliPath
                [IO.File]::Move($verified, $assetPath, $true)
            } finally {
                Remove-Item -LiteralPath $staging -Recurse -Force
            }
            $downloads.Add([string]$package.id)
            if ($exists) { $replaced.Add([string]$package.id) }
        }
        $assets.Add([pscustomobject][ordered]@{ id = $package.id; path = $assetPath; sha256 = $package.release.sha256; sizeBytes = $package.release.sizeBytes })
    }
    return [pscustomobject][ordered]@{
        catalogSha256 = $catalogHash; assetRoot = $assetRoot; assets = @($assets.ToArray())
        cacheHits = @($hits.ToArray()); replacedCorruptEntries = @($replaced.ToArray()); downloads = @($downloads.ToArray())
    }
}

function Get-VerifiedAsset {
    param(
        [Parameter(Mandatory)]$Package,
        [string]$OfflineAssetRoot,
        [Parameter(Mandatory)][string]$OperationRoot,
        [Parameter(Mandatory)][string]$GitHubCliPath
    )

    $assetPath = if ($OfflineAssetRoot) {
        Join-Path $OfflineAssetRoot ([string]$Package.release.asset)
    } else {
        Invoke-GitHubAssetDownload -Package $Package -DestinationDirectory $OperationRoot -GitHubCliPath $GitHubCliPath
    }
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Package '$($Package.id)' asset is missing: $assetPath"
    }
    $actualSize = (Get-Item -LiteralPath $assetPath).Length
    if ($actualSize -ne [long]$Package.release.sizeBytes) {
        throw "Package '$($Package.id)' asset size mismatch: expected $($Package.release.sizeBytes), found $actualSize."
    }
    $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne [string]$Package.release.sha256) {
        throw "Package '$($Package.id)' asset SHA-256 mismatch."
    }
    return $assetPath
}

function Expand-VerifiedZip {
    param(
        [Parameter(Mandatory)][string]$AssetPath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][long]$ExpandedSizeLimit
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($AssetPath)
    try {
        $totalSize = 0L
        foreach ($entry in $archive.Entries) {
            $entryPath = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }
            if ([IO.Path]::IsPathRooted($entryPath) -or $entryPath -match '^[A-Za-z]:' -or $entryPath.StartsWith('/') -or $entryPath.StartsWith('\')) {
                throw "Archive entry uses an absolute path: $entryPath"
            }
            if (@($entryPath -split '[\\/]') -contains '..') {
                throw "Archive entry contains parent traversal: $entryPath"
            }
            $attributes = [long]$entry.ExternalAttributes
            $unixType = ($attributes -shr 16) -band 0xF000
            if (($attributes -band [long][IO.FileAttributes]::ReparsePoint) -ne 0 -or $unixType -eq 0xA000) {
                throw "Archive entry is a reparse point or symbolic link: $entryPath"
            }
            $totalSize += [long]$entry.Length
            if ($totalSize -gt $ExpandedSizeLimit) {
                throw "Archive expanded size exceeds the catalog limit of $ExpandedSizeLimit bytes."
            }
        }

        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
        foreach ($entry in $archive.Entries) {
            $relativePath = ([string]$entry.FullName).Replace('/', [IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
            $outputPath = [IO.Path]::GetFullPath((Join-Path $destinationRoot $relativePath))
            if (-not $outputPath.StartsWith("$destinationRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes the staging directory: $relativePath"
            }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                [IO.Directory]::CreateDirectory($outputPath) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $outputPath)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $outputPath, $false)
        }
    } finally {
        $archive.Dispose()
    }
}

function Test-PackageProbes {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$ThrowOnFailure
    )

    try {
        foreach ($probe in @($Package.validation)) {
            $path = Join-Path $Destination ([string]$probe.path)
            switch -CaseSensitive ([string]$probe.type) {
                'file-exists' {
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Validation file is missing: $path" }
                }
                'file-version' {
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Validation file is missing: $path" }
                    $actual = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion
                    if ($actual -cne [string]$probe.version) { throw "Validation file version mismatch for '$path': expected $($probe.version), found $actual." }
                }
                'command-version' {
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Validation command is missing: $path" }
                    $arguments = if ($null -ne $probe.PSObject.Properties['arguments']) { @($probe.arguments) } else { @('--version') }
                    $output = & $path @arguments 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Validation command failed: $path" }
                    $text = [string]::Join([Environment]::NewLine, @($output))
                    if ($null -ne $probe.PSObject.Properties['pattern'] -and $text -notmatch [string]$probe.pattern) { throw "Validation command output did not match '$($probe.pattern)'." }
                    if ($null -ne $probe.PSObject.Properties['version'] -and $text -notmatch [regex]::Escape([string]$probe.version)) { throw "Validation command output did not contain version '$($probe.version)'." }
                }
                'sha256' {
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Validation file is missing: $path" }
                    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($actual -cne [string]$probe.sha256) { throw "Validation SHA-256 mismatch for '$path'." }
                }
                'authenticode-valid' {
                    if ((Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') { throw "Validation Authenticode signature is not valid: $path" }
                }
                'inf-provider-version' {
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Validation INF is missing: $path" }
                    $content = Get-Content -LiteralPath $path -Raw
                    if ($null -ne $probe.PSObject.Properties['provider'] -and $content -notmatch "(?im)^Provider\s*=\s*.*$([regex]::Escape([string]$probe.provider))") { throw "Validation INF provider mismatch: $path" }
                    if ($null -ne $probe.PSObject.Properties['version'] -and $content -notmatch "(?im)^DriverVer\s*=.*,$([regex]::Escape([string]$probe.version))\s*$") { throw "Validation INF version mismatch: $path" }
                }
                default { throw "Unsupported validation probe type '$($probe.type)'." }
            }
        }
        return $true
    } catch {
        if ($ThrowOnFailure) { throw }
        return $false
    }
}

function Get-DriverInfFiles {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Destination
    )

    $infFiles = @(Get-ChildItem -LiteralPath $Destination -Filter '*.inf' -File -Recurse)
    if ($infFiles.Count -eq 0) { throw "Driver package '$($Package.id)' contains no INF file." }
    return $infFiles
}

function Install-DriverPackage {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][object[]]$InfFiles,
        [Parameter(Mandatory)][string]$PnPUtilPath
    )

    foreach ($inf in $InfFiles) {
        $output = & $PnPUtilPath /add-driver $inf.FullName /install 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Driver installation failed for package '$PackageId': pnputil exited $LASTEXITCODE`: $([string]::Join([Environment]::NewLine, @($output)))"
        }
    }
}

function Write-InstalledState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$StatePath
    )

    [IO.Directory]::CreateDirectory((Split-Path -Parent $StatePath)) | Out-Null
    $temporaryPath = "$StatePath.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $State | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryPath, $StatePath, $true)
}

function Install-ToolchainProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][ValidateSet('ci-windows', 'dev-windows')][string]$Profile,
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$OfflineAssetRoot,
        [string]$StatePath,
        [string]$GitHubCliPath = 'gh',
        [string]$PnPUtilPath,
        [string]$RunnerImage = $env:RUNNER_LABEL,
        [string]$AssetCacheRoot,
        [switch]$AllowDowngrade
    )

    $catalog = Read-ToolchainCatalog -Path $CatalogPath
    $packages = @(Resolve-ToolchainProfile -Catalog $catalog -Profile $Profile)
    if ($Profile -ne 'dev-windows' -and @($packages | Where-Object { $_.install.kind -ceq 'driver' }).Count -gt 0) {
        throw 'Driver packages are permitted only in the dev-windows profile.'
    }
    if (-not $OfflineAssetRoot) {
        Import-Module (Join-Path $PSScriptRoot 'ToolchainPrerequisites.psm1') -Force
        $context = if ($Profile -ceq 'ci-windows') { 'ci' } else { 'developer' }
        Test-ToolchainPrerequisites -CatalogPath $CatalogPath -Context $context -RunnerImage $RunnerImage | Out-Null
        if (-not $AssetCacheRoot) {
            $AssetCacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'sonosystem-toolchain/cache'
        }
        $synchronized = Sync-ToolchainAssets -CatalogPath $CatalogPath -Profile $Profile -AssetCacheRoot $AssetCacheRoot -GitHubCliPath $GitHubCliPath
        $OfflineAssetRoot = $synchronized.assetRoot
    }
    if (-not $PnPUtilPath) { $PnPUtilPath = Join-Path $env:WINDIR 'System32\pnputil.exe' }
    $catalogSha256 = (Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    if (-not $StatePath) { $StatePath = Join-Path $InstallRoot 'installed-toolchain.json' }
    $StatePath = [IO.Path]::GetFullPath($StatePath)
    [IO.Directory]::CreateDirectory($InstallRoot) | Out-Null
    if ($OfflineAssetRoot) { Assert-OfflineAssetSet -Catalog $catalog -OfflineAssetRoot $OfflineAssetRoot }

    $previousState = Read-InstalledState -StatePath $StatePath
    $previousStateBytes = if (Test-Path -LiteralPath $StatePath -PathType Leaf) { [IO.File]::ReadAllBytes($StatePath) } else { $null }
    $operationRoot = Join-Path $InstallRoot ".toolchain-operation-$([Guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($operationRoot) | Out-Null
    $changes = [Collections.Generic.List[object]]::new()
    $statePackages = [Collections.Generic.List[object]]::new()
    $driversToInstall = [Collections.Generic.List[object]]::new()
    $driverExecutionStarted = $false

    try {
        foreach ($package in $packages) {
            $destination = Get-PackageDestination -Package $package -InstallRoot $InstallRoot
            $existing = Get-StatePackage -State $previousState -Id ([string]$package.id)
            if ($null -ne $existing -and (Compare-SemanticVersion -Left ([string]$package.version) -Right ([string]$existing.version)) -lt 0 -and -not $AllowDowngrade) {
                throw "Package '$($package.id)' downgrade from $($existing.version) to $($package.version) requires -AllowDowngrade."
            }

            $assetPath = Get-VerifiedAsset -Package $package -OfflineAssetRoot $OfflineAssetRoot -OperationRoot $operationRoot -GitHubCliPath $GitHubCliPath
            $stateMatches = $null -ne $existing -and $null -ne $existing.PSObject.Properties['recipeVersion'] -and [string]$existing.version -ceq [string]$package.version -and [string]$existing.sha256 -ceq [string]$package.release.sha256 -and [string]$existing.recipeVersion -ceq [string]$package.install.recipeVersion
            if ($stateMatches -and (Test-PackageProbes -Package $package -Destination $destination)) {
                $statePackages.Add($existing)
                continue
            }

            $stage = Join-Path $operationRoot "stage-$($package.id)-$([Guid]::NewGuid().ToString('N'))"
            switch -CaseSensitive ([string]$package.install.kind) {
                'zip' { Expand-VerifiedZip -AssetPath $assetPath -Destination $stage -ExpandedSizeLimit ([long]$package.install.expandedSizeBytes) }
                'driver' { Expand-VerifiedZip -AssetPath $assetPath -Destination $stage -ExpandedSizeLimit ([long]$package.install.expandedSizeBytes) }
                default { throw "Unsupported install kind '$($package.install.kind)'." }
            }
            Test-PackageProbes -Package $package -Destination $stage -ThrowOnFailure | Out-Null

            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            $backup = Join-Path $operationRoot "backup-$($package.id)-$([Guid]::NewGuid().ToString('N'))"
            $hadDestination = Test-Path -LiteralPath $destination
            if ($hadDestination) { Move-Item -LiteralPath $destination -Destination $backup }
            try {
                Move-Item -LiteralPath $stage -Destination $destination
            } catch {
                if ($hadDestination -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $destination }
                throw
            }
            $changes.Add([pscustomobject]@{ Destination = $destination; Backup = $backup; HadDestination = $hadDestination })

            Test-PackageProbes -Package $package -Destination $destination -ThrowOnFailure | Out-Null
            if ([string]$package.install.kind -ceq 'driver') {
                $driversToInstall.Add([pscustomobject]@{ Package = $package; Destination = $destination })
            }
            $statePackages.Add([ordered]@{
                id = [string]$package.id
                version = [string]$package.version
                sha256 = [string]$package.release.sha256
                recipeVersion = [int]$package.install.recipeVersion
                target = [string]$package.install.target
                destination = [string]$package.install.destination
            })
        }

        $preflightedDrivers = [Collections.Generic.List[object]]::new()
        foreach ($driver in $driversToInstall) {
            $infFiles = @(Get-DriverInfFiles -Package $driver.Package -Destination $driver.Destination)
            $preflightedDrivers.Add([pscustomobject]@{ PackageId = [string]$driver.Package.id; InfFiles = $infFiles })
        }
        foreach ($driver in $preflightedDrivers) {
            $driverExecutionStarted = $true
            Install-DriverPackage -PackageId $driver.PackageId -InfFiles $driver.InfFiles -PnPUtilPath $PnPUtilPath
        }

        $state = [ordered]@{
            schemaVersion = 1
            catalogId = [string]$catalog.catalogId
            catalogSha256 = $catalogSha256
            profile = $Profile
            packages = $statePackages.ToArray()
        }
        Write-InstalledState -State $state -StatePath $StatePath
        foreach ($change in $changes) {
            if (Test-Path -LiteralPath $change.Backup) { Remove-Item -LiteralPath $change.Backup -Recurse -Force }
        }
        return $state
    } catch {
        $failure = $_
        $rollbackFailure = $null
        try {
            for ($index = $changes.Count - 1; $index -ge 0; $index--) {
                $change = $changes[$index]
                if (Test-Path -LiteralPath $change.Destination) { Remove-Item -LiteralPath $change.Destination -Recurse -Force }
                if ($change.HadDestination -and (Test-Path -LiteralPath $change.Backup)) { Move-Item -LiteralPath $change.Backup -Destination $change.Destination }
            }
            if ($null -ne $previousStateBytes) {
                [IO.File]::WriteAllBytes($StatePath, $previousStateBytes)
            } elseif (Test-Path -LiteralPath $StatePath) {
                Remove-Item -LiteralPath $StatePath -Force
            }
        } catch {
            $rollbackFailure = $_
        }
        if ($driverExecutionStarted) {
            $details = $failure.Exception.Message
            if ($null -ne $rollbackFailure) { $details += " Rollback also failed: $($rollbackFailure.Exception.Message)" }
            throw "Toolchain installation failed after driver execution began: $details. Driver Store changes may be partial; cleanup and reboot may be required."
        }
        if ($null -ne $rollbackFailure) { throw $rollbackFailure }
        throw $failure
    } finally {
        try {
            if (Test-Path -LiteralPath $operationRoot) { Remove-Item -LiteralPath $operationRoot -Recurse -Force }
        } catch {
            if ($driverExecutionStarted) {
                throw "Operation cleanup failed after driver execution began: $($_.Exception.Message). Driver Store changes may be partial; cleanup and reboot may be required."
            }
            throw
        }
    }
}

function Test-InstalledToolchain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][ValidateSet('ci-windows', 'dev-windows')][string]$Profile,
        [Parameter(Mandatory)][string]$StatePath,
        [string]$InstallRoot = (Split-Path -Parent $StatePath)
    )

    $catalog = Read-ToolchainCatalog -Path $CatalogPath
    $catalogSha256 = (Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $packages = @(Resolve-ToolchainProfile -Catalog $catalog -Profile $Profile)
    $state = Read-InstalledState -StatePath $StatePath
    if ($null -eq $state) { throw "Installed toolchain state does not exist: $StatePath" }
    if ([string]$state.catalogId -cne [string]$catalog.catalogId -or [string]$state.catalogSha256 -cne $catalogSha256 -or [string]$state.profile -cne $Profile) {
        throw 'Installed toolchain state does not match the selected catalog and profile.'
    }
    if (@($state.packages).Count -ne $packages.Count) { throw 'Installed toolchain package count does not match the selected profile.' }
    for ($index = 0; $index -lt $packages.Count; $index++) {
        $package = $packages[$index]
        $record = @($state.packages)[$index]
        if ([string]$record.id -cne [string]$package.id -or [string]$record.version -cne [string]$package.version -or [string]$record.sha256 -cne [string]$package.release.sha256 -or [string]$record.recipeVersion -cne [string]$package.install.recipeVersion) {
            throw "Installed toolchain state mismatch at package '$($package.id)'."
        }
        $destination = Get-PackageDestination -Package $package -InstallRoot $InstallRoot
        Test-PackageProbes -Package $package -Destination $destination -ThrowOnFailure | Out-Null
    }
}

Export-ModuleMember -Function Install-ToolchainProfile, Test-InstalledToolchain, Sync-ToolchainAssets
