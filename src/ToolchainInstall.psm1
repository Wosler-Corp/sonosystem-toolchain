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
    return @($State.packages | Where-Object { [string]$_.id -ceq $Id } | Select-Object -First 1)[0]
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
    $lastOutput = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $output = & $GitHubCliPath @downloadArguments 2>&1
        $exitCode = $LASTEXITCODE
        $lastOutput = [string]::Join([Environment]::NewLine, @($output))
        if ($exitCode -eq 0) { break }
        if ($lastOutput -notmatch '(?<!\d)(408|429|5\d\d)(?!\d)' -or $attempt -eq 3) {
            throw "Failed to download Wosler release asset '$asset': $lastOutput"
        }
        Start-Sleep -Seconds $attempt
    }

    $assetPath = Join-Path $DestinationDirectory $asset
    $verifyOutput = & $GitHubCliPath release verify-asset $tag $assetPath --repo $repository 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub release attestation verification failed for '$asset': $([string]::Join([Environment]::NewLine, @($verifyOutput)))"
    }
    return $assetPath
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

function Install-DriverPackage {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Destination
    )

    $infFiles = @(Get-ChildItem -LiteralPath $Destination -Filter '*.inf' -File -Recurse)
    if ($infFiles.Count -eq 0) { throw "Driver package '$($Package.id)' contains no INF file." }
    $pnputil = Join-Path $env:WINDIR 'System32\pnputil.exe'
    foreach ($inf in $infFiles) {
        $output = & $pnputil /add-driver $inf.FullName /install 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Driver installation failed for '$($inf.FullName)': $([string]::Join([Environment]::NewLine, @($output)))" }
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
        [ValidateSet('Image', 'Developer')][string]$Mode = 'Developer',
        [switch]$AllowDowngrade
    )

    $catalog = Read-ToolchainCatalog -Path $CatalogPath
    $packages = @(Resolve-ToolchainProfile -Catalog $catalog -Profile $Profile)
    if ($Mode -eq 'Image' -and @($packages | Where-Object { $_.install.kind -ceq 'driver' }).Count -gt 0) {
        throw 'Driver packages cannot be installed in image mode.'
    }

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

    try {
        foreach ($package in $packages) {
            $destination = Get-PackageDestination -Package $package -InstallRoot $InstallRoot
            $existing = Get-StatePackage -State $previousState -Id ([string]$package.id)
            if ($null -ne $existing -and (Compare-SemanticVersion -Left ([string]$package.version) -Right ([string]$existing.version)) -lt 0 -and -not $AllowDowngrade) {
                throw "Package '$($package.id)' downgrade from $($existing.version) to $($package.version) requires -AllowDowngrade."
            }

            $assetPath = Get-VerifiedAsset -Package $package -OfflineAssetRoot $OfflineAssetRoot -OperationRoot $operationRoot -GitHubCliPath $GitHubCliPath
            $stateMatches = $null -ne $existing -and [string]$existing.version -ceq [string]$package.version -and [string]$existing.sha256 -ceq [string]$package.release.sha256
            if ($stateMatches -and (Test-PackageProbes -Package $package -Destination $destination)) {
                $statePackages.Add($existing)
                continue
            }

            $stage = Join-Path $operationRoot "stage-$($package.id)-$([Guid]::NewGuid().ToString('N'))"
            switch -CaseSensitive ([string]$package.install.kind) {
                'zip' { Expand-VerifiedZip -AssetPath $assetPath -Destination $stage -ExpandedSizeLimit ([long]$package.install.expandedSizeBytes) }
                'driver' { Expand-VerifiedZip -AssetPath $assetPath -Destination $stage -ExpandedSizeLimit ([long]$package.install.expandedSizeBytes) }
                'msi' { [IO.Directory]::CreateDirectory($stage) | Out-Null; Copy-Item -LiteralPath $assetPath -Destination (Join-Path $stage ([IO.Path]::GetFileName($assetPath))) }
                'exe' { [IO.Directory]::CreateDirectory($stage) | Out-Null; Copy-Item -LiteralPath $assetPath -Destination (Join-Path $stage ([IO.Path]::GetFileName($assetPath))) }
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
            if ([string]$package.install.kind -ceq 'driver') { Install-DriverPackage -Package $package -Destination $destination }
            $statePackages.Add([ordered]@{
                id = [string]$package.id
                version = [string]$package.version
                sha256 = [string]$package.release.sha256
                target = [string]$package.install.target
                destination = [string]$package.install.destination
            })
        }

        $state = [ordered]@{
            schemaVersion = 1
            catalogId = [string]$catalog.catalogId
            profile = $Profile
            packages = $statePackages.ToArray()
        }
        Write-InstalledState -State $state -StatePath $StatePath
        foreach ($change in $changes) {
            if (Test-Path -LiteralPath $change.Backup) { Remove-Item -LiteralPath $change.Backup -Recurse -Force }
        }
        return $state
    } catch {
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
        throw
    } finally {
        if (Test-Path -LiteralPath $operationRoot) { Remove-Item -LiteralPath $operationRoot -Recurse -Force }
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
    $packages = @(Resolve-ToolchainProfile -Catalog $catalog -Profile $Profile)
    $state = Read-InstalledState -StatePath $StatePath
    if ($null -eq $state) { throw "Installed toolchain state does not exist: $StatePath" }
    if ([string]$state.catalogId -cne [string]$catalog.catalogId -or [string]$state.profile -cne $Profile) {
        throw 'Installed toolchain state does not match the selected catalog and profile.'
    }
    if (@($state.packages).Count -ne $packages.Count) { throw 'Installed toolchain package count does not match the selected profile.' }
    for ($index = 0; $index -lt $packages.Count; $index++) {
        $package = $packages[$index]
        $record = @($state.packages)[$index]
        if ([string]$record.id -cne [string]$package.id -or [string]$record.version -cne [string]$package.version -or [string]$record.sha256 -cne [string]$package.release.sha256) {
            throw "Installed toolchain state mismatch at package '$($package.id)'."
        }
        $destination = Get-PackageDestination -Package $package -InstallRoot $InstallRoot
        Test-PackageProbes -Package $package -Destination $destination -ThrowOnFailure | Out-Null
    }
}

Export-ModuleMember -Function Install-ToolchainProfile, Test-InstalledToolchain
