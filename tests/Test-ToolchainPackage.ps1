[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$builderPath = Join-Path $repoRoot 'scripts\New-ToolchainPackage.ps1'
$definitionValidatorPath = Join-Path $repoRoot 'scripts\Test-PackageDefinition.ps1'
foreach ($requiredPath in @($builderPath, $definitionValidatorPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Toolchain package component not found: $requiredPath"
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:passed = 0
$script:failed = 0

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [Parameter(Mandatory)][string]$Message)
    $actualJson = ConvertTo-Json -InputObject $Actual -Depth 100 -Compress
    $expectedJson = ConvertTo-Json -InputObject $Expected -Depth 100 -Compress
    if ($actualJson -cne $expectedJson) { throw "$Message. Expected $expectedJson, found $actualJson." }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$MessagePattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "Expected error matching '$MessagePattern', found '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error matching '$MessagePattern', but no error was thrown."
}

function Invoke-Test {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        Write-Host "PASS: $Name"
    } catch {
        $script:failed++
        Write-Error "FAIL: ${Name}: $($_.Exception.Message)" -ErrorAction Continue
    }
}

function New-TestEnvironment {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $root = Join-Path $base "toolchain-package-test-$([Guid]::NewGuid().ToString('N'))"
    $source = Join-Path $root 'source'
    [IO.Directory]::CreateDirectory((Join-Path $source 'z-last')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $source 'a-first')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'z-last\tool.exe'), 'tool-content', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $source 'a-first\config.txt'), 'config-content', [Text.UTF8Encoding]::new($false))
    (Get-Item -LiteralPath (Join-Path $source 'z-last\tool.exe')).LastWriteTimeUtc = [datetime]'2025-05-01T12:13:14Z'
    (Get-Item -LiteralPath (Join-Path $source 'a-first\config.txt')).LastWriteTimeUtc = [datetime]'2020-01-02T03:04:06Z'
    return [pscustomobject]@{
        Root = $root
        Source = $source
        Definition = Join-Path $root 'definition.json'
        OutputOne = Join-Path $root 'out-one'
        OutputTwo = Join-Path $root 'out-two'
    }
}

function Remove-TestEnvironment {
    param([Parameter(Mandatory)]$Environment)
    if (Test-Path -LiteralPath $Environment.Root) { Remove-Item -LiteralPath $Environment.Root -Recurse -Force }
}

function Get-DirectorySourceIdentity {
    param([Parameter(Mandatory)][string]$Path)

    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $records = [Collections.Generic.List[string]]::new()
    $size = 0L
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse)) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $records.Add("$relative`0$hash`0$($file.Length)")
        $size += $file.Length
    }
    $recordArray = $records.ToArray()
    [Array]::Sort($recordArray, [StringComparer]::Ordinal)
    $manifest = [string]::Join("`n", $recordArray)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($manifest)
    $sha = [Security.Cryptography.SHA256]::HashData($bytes)
    return [pscustomobject]@{
        Sha256 = [Convert]::ToHexString($sha).ToLowerInvariant()
        SizeBytes = $size
    }
}

function Get-FileSourceIdentity {
    param([Parameter(Mandatory)][string]$Path)
    return [pscustomobject]@{
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        SizeBytes = (Get-Item -LiteralPath $Path).Length
    }
}

function Write-Definition {
    param(
        [Parameter(Mandatory)]$Environment,
        [string]$Kind = 'zip',
        [string]$Asset = 'runtime-1.0.0.zip',
        [string]$SourcePath = $Environment.Source,
        $Authenticode = $null
    )

    $identity = if (Test-Path -LiteralPath $SourcePath -PathType Container) {
        Get-DirectorySourceIdentity -Path $SourcePath
    } else {
        Get-FileSourceIdentity -Path $SourcePath
    }
    $source = [ordered]@{
        sha256 = $identity.Sha256
        sizeBytes = $identity.SizeBytes
    }
    if ($null -ne $Authenticode) { $source.authenticode = $Authenticode }
    $definition = [ordered]@{
        schemaVersion = 1
        id = 'runtime'
        version = '1.0.0'
        kind = $Kind
        asset = $Asset
        source = $source
        upstream = [ordered]@{
            url = 'https://vendor.invalid/runtime-1.0.0.zip'
            version = '1.0.0'
            retrievedAt = '2026-09-29T00:00:00Z'
        }
        licenses = @('licenses/runtime/1.0.0/LICENSE.txt')
    }
    [IO.File]::WriteAllText($Environment.Definition, ($definition | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    return $definition
}

function Invoke-Builder {
    param(
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$SourcePath = $Environment.Source
    )
    & $builderPath -DefinitionPath $Environment.Definition -SourcePath $SourcePath -OutputDirectory $OutputDirectory | Out-Null
}

Invoke-Test 'builds byte-identical archives and sidecar digests' {
    $environment = New-TestEnvironment
    try {
        Write-Definition -Environment $environment | Out-Null
        Invoke-Builder -Environment $environment -OutputDirectory $environment.OutputOne
        Invoke-Builder -Environment $environment -OutputDirectory $environment.OutputTwo
        foreach ($name in @('runtime-1.0.0.zip', 'runtime-1.0.0.zip.sha256', 'runtime-1.0.0.zip.provenance.json')) {
            $hashOne = (Get-FileHash -LiteralPath (Join-Path $environment.OutputOne $name) -Algorithm SHA256).Hash
            $hashTwo = (Get-FileHash -LiteralPath (Join-Path $environment.OutputTwo $name) -Algorithm SHA256).Hash
            Assert-Equal -Actual $hashOne -Expected $hashTwo -Message "$name was not deterministic"
        }
    } finally { Remove-TestEnvironment $environment }
}

Invoke-Test 'normalizes ZIP entry ordering and timestamps' {
    $environment = New-TestEnvironment
    try {
        Write-Definition -Environment $environment | Out-Null
        Invoke-Builder -Environment $environment -OutputDirectory $environment.OutputOne
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $environment.OutputOne 'runtime-1.0.0.zip'))
        try {
            $names = @($archive.Entries | ForEach-Object { $_.FullName })
            Assert-Equal -Actual $names -Expected @('a-first/config.txt', 'z-last/tool.exe') -Message 'ZIP entries are not in ordinal path order'
            foreach ($entry in $archive.Entries) {
                # ZIP stores wall-clock fields without a UTC offset.
                Assert-Equal -Actual $entry.LastWriteTime.DateTime.ToString('o') -Expected '2000-01-01T00:00:00.0000000' -Message "ZIP timestamp was not normalized for $($entry.FullName)"
            }
        } finally { $archive.Dispose() }
    } finally { Remove-TestEnvironment $environment }
}

foreach ($missingField in @('licenses', 'upstream')) {
    Invoke-Test "rejects missing $missingField metadata" {
        $environment = New-TestEnvironment
        try {
            $definition = Write-Definition -Environment $environment
            $definition.Remove($missingField)
            [IO.File]::WriteAllText($environment.Definition, ($definition | ConvertTo-Json -Depth 100))
            Assert-Throws -MessagePattern $missingField -Action { Invoke-Builder -Environment $environment -OutputDirectory $environment.OutputOne }
        } finally { Remove-TestEnvironment $environment }
    }
}

foreach ($mismatch in @('sizeBytes', 'sha256')) {
    Invoke-Test "rejects source $mismatch mismatch" {
        $environment = New-TestEnvironment
        try {
            $definition = Write-Definition -Environment $environment
            if ($mismatch -eq 'sizeBytes') { $definition.source.sizeBytes++ } else { $definition.source.sha256 = 'd' * 64 }
            [IO.File]::WriteAllText($environment.Definition, ($definition | ConvertTo-Json -Depth 100))
            Assert-Throws -MessagePattern 'source.*(size|SHA-256)|size.*mismatch|SHA-256.*mismatch' -Action { Invoke-Builder -Environment $environment -OutputDirectory $environment.OutputOne }
        } finally { Remove-TestEnvironment $environment }
    }
}

Invoke-Test 'rejects an Authenticode signature mismatch' {
    $environment = New-TestEnvironment
    try {
        $binaryPath = Join-Path $environment.Root 'unsigned.exe'
        [IO.File]::WriteAllText($binaryPath, 'unsigned-binary')
        Write-Definition -Environment $environment -Kind 'exe' -Asset 'unsigned.exe' -SourcePath $binaryPath `
            -Authenticode ([ordered]@{ status = 'Valid' }) | Out-Null
        Assert-Throws -MessagePattern 'Authenticode|signature' -Action {
            Invoke-Builder -Environment $environment -SourcePath $binaryPath -OutputDirectory $environment.OutputOne
        }
    } finally { Remove-TestEnvironment $environment }
}

Invoke-Test 'rejects package output inside the Git working tree' {
    $environment = New-TestEnvironment
    try {
        Write-Definition -Environment $environment | Out-Null
        $forbidden = Join-Path $repoRoot 'generated-packages-forbidden'
        Assert-Throws -MessagePattern 'Git working tree|working tree' -Action {
            Invoke-Builder -Environment $environment -OutputDirectory $forbidden
        }
        Assert-True -Condition (-not (Test-Path -LiteralPath $forbidden)) -Message 'Rejected output created a directory in the repository.'
    } finally { Remove-TestEnvironment $environment }
}

Invoke-Test 'does not leak host paths into provenance metadata' {
    $environment = New-TestEnvironment
    try {
        Write-Definition -Environment $environment | Out-Null
        Invoke-Builder -Environment $environment -OutputDirectory $environment.OutputOne
        $provenance = [IO.File]::ReadAllText((Join-Path $environment.OutputOne 'runtime-1.0.0.zip.provenance.json'))
        Assert-True -Condition (-not $provenance.Contains($environment.Root)) -Message 'Provenance contains a host-specific absolute path.'
    } finally { Remove-TestEnvironment $environment }
}

function Assert-PackageArchiveEvidence {
    param([Parameter(Mandatory)]$Definition, [string]$EvidenceRoot = $repoRoot)
    $verification = $Definition.verification
    Assert-True -Condition ([string]$verification.archiveSha256 -cmatch '^[0-9a-f]{64}$') -Message 'Archive evidence is missing'
    Assert-True -Condition ($verification.archiveSizeBytes -gt 0) -Message 'Archive size is missing'
    $mode = 'built'
    if ($null -ne $Definition.PSObject.Properties['acquisition']) { $mode = [string]$Definition.acquisition.mode }
    if ($mode -ceq 'built') {
        if ($null -ne $Definition.PSObject.Properties['acquisition']) {
            Assert-True -Condition ($null -eq $Definition.acquisition.PSObject.Properties['sourceRelease'] -and $null -eq $Definition.acquisition.PSObject.Properties['downloadVerification']) -Message 'Built mode must not carry reuse-only evidence'
        }
        Assert-Equal -Actual $verification.secondBuildSha256 -Expected $verification.archiveSha256 -Message 'Rebuild differs'
        return
    }
    Assert-Equal -Actual $mode -Expected 'reuse-existing-release' -Message 'Unknown acquisition mode'
    $approved = @{
        'boost-mingw' = @{ asset = 'boost-1.86.0-windows-x86_64-gcc14.2-mingw.zip'; size = 39562973L; hash = '8c9208bdf80c934c4013f8bdca43a092d69020a7f0487135e2ae3f8e7487a31b'; assetId = 531194847L; manifestHash = 'e386a1d68a97c6974f30943a7cae59658c723ec0ff90557a9dd61cd3e1f4e0c6'; treeHash = '98fa0abcd9d3c09b1e8d30f39ab8ce5fdd9aca7dd676af43561e77fce8ff9f54'; expanded = 211503636L; files = 15955 }
        'boost-msvc' = @{ asset = 'boost-1.86.0-windows-x86_64-msvc19.43-v143.zip'; size = 78227427L; hash = '6246a880c74fc59ed23b611f052230624ba7be3277bd9324352c860b82c1facc'; assetId = 531195129L; manifestHash = 'e0d8021de9f710200904b4b42250d607dbe75710add6baf09cba1f5a130d52cc'; treeHash = '79071a8a19a4ab8a7b31d0cd4f42b123d7e27aa6d11f8562070d344b6b0f15df'; expanded = 481957717L; files = 16042 }
    }
    Assert-True -Condition ($Definition.id -cin @('boost-mingw', 'boost-msvc')) -Message 'Reuse is allowed only for the two approved Boost packages'
    $expected = $approved[$Definition.id]
    Assert-Equal -Actual $Definition.asset -Expected $expected.asset -Message 'Archive is not the approved Boost asset'
    Assert-Equal -Actual $verification.archiveSha256 -Expected $expected.hash -Message 'Archive is not the approved Boost hash'
    Assert-Equal -Actual ([long]$verification.archiveSizeBytes) -Expected $expected.size -Message 'Archive is not the approved Boost size'
    Assert-Equal -Actual $Definition.version -Expected '1.86.0' -Message 'Reuse version differs'
    Assert-True -Condition ($null -eq $verification.PSObject.Properties['secondBuildSha256']) -Message 'Reuse must not claim a second build'
    $acquisition = $Definition.acquisition
    $source = $acquisition.sourceRelease
    $download = $acquisition.downloadVerification
    Assert-Equal -Actual $source.repository -Expected 'Wosler-Corp/sonosystem-toolchain' -Message 'Reuse source must be the Wosler toolchain repository'
    Assert-Equal -Actual ([long]$source.releaseId) -Expected 377351005L -Message 'Reuse release ID differs'
    Assert-Equal -Actual ([long]$source.assetId) -Expected $expected.assetId -Message 'Reuse asset ID differs'
    Assert-Equal -Actual $source.tag -Expected 'boost-1.86.0' -Message 'Reuse tag differs'
    Assert-Equal -Actual $source.releaseUrl -Expected 'https://github.com/Wosler-Corp/sonosystem-toolchain/releases/tag/boost-1.86.0' -Message 'Reuse release URL differs'
    foreach ($field in @('releaseId', 'assetId')) {
        Assert-True -Condition ([string]$source.$field -cmatch '^[1-9][0-9]*$') -Message "Missing reuse $field"
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$source.tag)) -Message 'Missing reuse tag'
    Assert-Equal -Actual $source.assetName -Expected $Definition.asset -Message 'Reuse asset name differs'
    $expectedUrl = "https://github.com/$($source.repository)/releases/download/$($source.tag)/$($Definition.asset)"
    Assert-Equal -Actual $source.url -Expected $expectedUrl -Message 'Reuse source URL differs'
    Assert-True -Condition ($source.observedImmutable -is [bool] -and -not $source.observedImmutable) -Message 'Reuse source must record observed immutable:false'
    Assert-Equal -Actual $source.sourceStatus -Expected 'verified-source-input-only' -Message 'Reuse source must not claim publication attestation'
    Assert-True -Condition ($acquisition.task5CopyRequired -is [bool] -and $acquisition.task5CopyRequired) -Message 'Task5 copy must remain required'
    foreach ($field in @('rebuilt', 'recompressed')) {
        Assert-True -Condition ($Definition.provenance.$field -is [bool] -and -not $Definition.provenance.$field) -Message "Reuse provenance must record $field=false"
    }
    Assert-True -Condition ($verification.buildReproducibility.performed -is [bool] -and -not $verification.buildReproducibility.performed) -Message 'Reuse must not claim a performed rebuild'
    Assert-Equal -Actual $download.sha256 -Expected $verification.archiveSha256 -Message 'Downloaded archive hash differs'
    Assert-Equal -Actual ([long]$download.sizeBytes) -Expected ([long]$verification.archiveSizeBytes) -Message 'Downloaded archive size differs'
    $verifiedAt = [datetimeoffset]::MinValue
    Assert-True -Condition ([datetimeoffset]::TryParse([string]$download.verifiedAt, [ref]$verifiedAt)) -Message 'Download verification timestamp is missing'
    Assert-Equal -Actual @($Definition.inputs).Count -Expected 1 -Message 'Reuse inputs must contain only the incorporated archive'
    $input = @($Definition.inputs)[0]
    Assert-Equal -Actual $input.url -Expected $source.url -Message 'Reuse input URL differs'
    Assert-Equal -Actual $input.originalFilename -Expected $Definition.asset -Message 'Reuse input filename differs'
    Assert-Equal -Actual $input.sha256 -Expected $download.sha256 -Message 'Reuse input hash differs'
    Assert-Equal -Actual ([long]$input.sizeBytes) -Expected ([long]$download.sizeBytes) -Message 'Reuse input size differs'
    Assert-Equal -Actual $verification.offline.status -Expected 'passed' -Message 'Reuse offline verification did not pass'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$verification.offline.method)) -Message 'Reuse offline method is missing'
    Assert-Equal -Actual $verification.offline.link -Expected 'shared' -Message 'Reuse smoke must verify shared linking'
    Assert-Equal -Actual @($verification.offline.components | Sort-Object) -Expected @('atomic', 'chrono', 'thread') -Message 'Reuse smoke components differ'
    $expectedVariants = if ($Definition.id -ceq 'boost-msvc') { @('debug', 'release') } else { @('release') }
    Assert-Equal -Actual @($verification.offline.variants.PSObject.Properties.Name | Sort-Object) -Expected @($expectedVariants) -Message 'Reuse smoke variants differ'
    $variants = @($verification.offline.variants.PSObject.Properties)
    Assert-True -Condition ($variants.Count -gt 0) -Message 'Reuse offline variants are missing'
    foreach ($variant in $variants) {
        foreach ($field in @('configureExitCode', 'buildExitCode', 'runtimeExitCode')) {
            Assert-Equal -Actual $variant.Value.$field -Expected 0 -Message "Reuse $($variant.Name) $field did not pass"
        }
    }
    Assert-Equal -Actual $verification.reinstall.status -Expected 'passed' -Message 'Reuse reinstall verification did not pass'
    foreach ($field in @('payloadAndStateUnchanged', 'stateUnchanged', 'payloadTimestampsUnchanged')) {
        Assert-True -Condition ($verification.reinstall.$field -is [bool] -and $verification.reinstall.$field) -Message "Reuse reinstall lacks $field"
    }
    $manifestRelative = "packages/windows/contents/$($Definition.id)-1.86.0.json"
    Assert-Equal -Actual $Definition.contents.manifest -Expected $manifestRelative -Message 'Reuse manifest path differs'
    Assert-Equal -Actual $Definition.contents.manifestSha256 -Expected $expected.manifestHash -Message 'Reuse manifest identity differs'
    $manifestPath = Join-Path $EvidenceRoot $manifestRelative
    Assert-True -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Message 'Reuse content manifest is missing'
    Assert-Equal -Actual (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -Expected $expected.manifestHash -Message 'Reuse content manifest bytes differ'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20
    Assert-Equal -Actual $manifest.archive -Expected $expected.asset -Message 'Manifest archive differs'
    Assert-Equal -Actual $manifest.archiveSha256 -Expected $expected.hash -Message 'Manifest archive hash differs'
    Assert-Equal -Actual @($manifest.files).Count -Expected $expected.files -Message 'Manifest file inventory is incomplete'
    Assert-Equal -Actual $Definition.contents.fileCount -Expected $expected.files -Message 'Definition file count differs'
    $records = [Collections.Generic.List[string]]::new()
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expanded = 0L
    foreach ($file in $manifest.files) {
        Assert-True -Condition ($file.path.StartsWith('boost-1.86.0/', [StringComparison]::Ordinal) -and -not ($file.path -match '(^|/)\.\.(/|$)|\\')) -Message 'Manifest layout differs'
        Assert-True -Condition ($paths.Add([string]$file.path)) -Message 'Manifest contains duplicate file paths'
        Assert-True -Condition ([string]$file.sha256 -cmatch '^[0-9a-f]{64}$' -and [long]$file.sizeBytes -ge 0) -Message 'Manifest file identity is invalid'
        $records.Add("$($file.path)`0$($file.sha256)`0$($file.sizeBytes)")
        $expanded += [long]$file.sizeBytes
    }
    $ordered = $records.ToArray(); [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $treeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $ordered)))).ToLowerInvariant()
    foreach ($hash in @($treeHash, $manifest.treeSha256, $Definition.source.sha256)) { Assert-Equal -Actual $hash -Expected $expected.treeHash -Message 'Full source tree identity differs' }
    foreach ($size in @($expanded, $manifest.expandedSizeBytes, $Definition.source.sizeBytes, $Definition.contents.expandedSizeBytes)) { Assert-Equal -Actual ([long]$size) -Expected $expected.expanded -Message 'Expanded tree size differs' }
    $layout = @{ archiveRoot='boost-1.86.0'; destination=$Definition.id; include='boost-1.86.0/include'; libraries='boost-1.86.0/lib'; binaries='boost-1.86.0/bin' }
    foreach ($field in $layout.Keys) { Assert-Equal -Actual $Definition.installLayout.$field -Expected $layout[$field] -Message "Reuse $field layout differs" }
    Assert-True -Condition ($Definition.installLayout.flattenArchive -is [bool] -and -not $Definition.installLayout.flattenArchive) -Message 'Reuse layout must retain archive wrapper'
    Assert-Equal -Actual @($Definition.contents.dlls | Sort-Object) -Expected @($manifest.files.path | Where-Object { $_ -match '/bin/[^/]+\.dll$' } | Sort-Object) -Message 'DLL content inventory differs'
    Assert-Equal -Actual @($Definition.contents.libraries | Sort-Object) -Expected @($manifest.files.path | Where-Object { $_ -match '/lib/[^/]+\.(a|lib)$' } | Sort-Object) -Message 'Library content inventory differs'
    if ($Definition.id -ceq 'boost-mingw') {
        Assert-Equal -Actual @($Definition.dependencies) -Expected @('msys2-sonosystem') -Message 'Frozen MSYS2 dependency is missing'
        Assert-Equal -Actual @($Definition.closure.installationOrder) -Expected @('msys2-sonosystem', 'boost-mingw') -Message 'Runtime installation order differs'
        Assert-Equal -Actual @($Definition.closure.runtimePathOrder) -Expected @('<toolchain-root>/boost-mingw/boost-1.86.0/bin', '<toolchain-root>/msys2-sonosystem/mingw64/bin', 'Windows system directories') -Message 'Runtime PATH order differs'
        Assert-True -Condition ($verification.offline.staticLibraries.present -is [bool] -and $verification.offline.staticLibraries.present -and $verification.offline.staticLibraries.consumerTested -is [bool] -and -not $verification.offline.staticLibraries.consumerTested) -Message 'Static libraries must be present but not consumer-tested'
        Assert-Equal -Actual $verification.offline.staticLibraries.validationStatus -Expected 'presence-only-not-consumer-tested' -Message 'Static validation claim differs'
        Assert-True -Condition (@($manifest.files.path | Where-Object { $_ -match '/lib/[^/]+\.a$' -and $_ -notmatch '\.dll\.a$' }).Count -gt 0) -Message 'Static presence evidence is missing'
        $runtimePackages = @{
            'mingw-w64-x86_64-gcc-libs' = @('14.2.0-1', '3ac4352d1a4dec21508a71d744ff055d5643b2937c799b11114a33066abfb963', '6ef208050c3d8818f2f6f5782731f40e60df6dd0eef908e2d253e29dfa3807ca')
            'mingw-w64-x86_64-libwinpthread-git' = @('12.0.0.r320.g335ffe5b7-1', '244e3ee1f23ee0645307a80009a65c7b9d24a3d277d42b909d3d699c5e4bd619', 'bf74f54e6663f86866587426bb7ce9282b5a32ce2f923e0047ce5dee5b5bd10f')
            'mingw-w64-x86_64-libiconv' = @('1.17-4', 'ceedb36b46fe8e6ff69d619774c4d2ce1f118b50ee6a00194d874855c3ae6a57', '084b4d7c51f6f87c464d6c68c35af2ecbb52122149462cc2fb621b7c5c899a55')
        }
        Assert-Equal -Actual @($Definition.closure.runtimeDependencies.name | Sort-Object) -Expected @($runtimePackages.Keys | Sort-Object) -Message 'Frozen runtime package set differs'
        foreach ($package in $Definition.closure.runtimeDependencies) {
            $pin = $runtimePackages[$package.name]
            Assert-Equal -Actual @($package.version, $package.sha256, $package.signatureSha256) -Expected @($pin) -Message 'Frozen runtime package identity differs'
            Assert-Equal -Actual $package.ownerPackage -Expected 'msys2-sonosystem' -Message 'Runtime ownership differs'
            Assert-Equal -Actual $package.signatureStatus -Expected 'Valid' -Message 'Runtime signature missing'
            Assert-Equal -Actual $package.signerFingerprint -Expected '5F944B027F7FE2091985AA2EFA11531AA0AA7F57' -Message 'Runtime signature identity differs'
            Assert-True -Condition ($package.bundledInThisArchive -is [bool] -and -not $package.bundledInThisArchive) -Message 'External runtime must not be claimed bundled'
        }
        $runtimeFiles = @{
            'libgcc_s_seh-1.dll' = @('0e057fccb0e7656bd096bf25a4714e74245ea02b644dafcc2106f8c524fcc535', 'mingw-w64-x86_64-gcc-libs', '14.2.0-1')
            'libstdc++-6.dll' = @('713e5d696c6929b9c4cd9186ef0baaba3e1d30b42f43b60d4bbb44525d832e4d', 'mingw-w64-x86_64-gcc-libs', '14.2.0-1')
            'libwinpthread-1.dll' = @('1a4f9324673d884914b0fd1a6c55f8bcc84f2cbef52c46d0e4d0a541e0759837', 'mingw-w64-x86_64-libwinpthread-git', '12.0.0.r320.g335ffe5b7-1')
            'libiconv-2.dll' = @('967189adfbc889fde89aafc867f7a1f02731f8592cf6fd5a4ace1929213e2e13', 'mingw-w64-x86_64-libiconv', '1.17-4')
        }
        Assert-Equal -Actual @($Definition.closure.runtimeFiles.name | Sort-Object) -Expected @($runtimeFiles.Keys | Sort-Object) -Message 'Frozen runtime DLL set differs'
        foreach ($file in $Definition.closure.runtimeFiles) { Assert-Equal -Actual @($file.sha256, $file.package, $file.packageVersion) -Expected @($runtimeFiles[$file.name]) -Message 'Frozen runtime DLL identity differs' }
    } else {
        Assert-Equal -Actual @($Definition.dependencies) -Expected @() -Message 'MSVC package dependencies differ'
    }
}

function New-ReuseEvidenceFixture {
    param([ValidateSet('boost-mingw', 'boost-msvc')][string]$Id = 'boost-mingw')
    return Get-Content -LiteralPath (Join-Path $repoRoot "packages/windows/$Id.json") -Raw | ConvertFrom-Json -Depth 100
}

Invoke-Test 'archive evidence keeps built-package reproducibility checks' {
    $built = [pscustomobject]@{ verification = [pscustomobject]@{ archiveSha256 = ('a' * 64); archiveSizeBytes = 123; secondBuildSha256 = ('a' * 64) } }
    Assert-PackageArchiveEvidence -Definition $built
    $built.verification.secondBuildSha256 = 'b' * 64
    Assert-Throws -Action { Assert-PackageArchiveEvidence -Definition $built } -MessagePattern 'Rebuild differs'
}

Invoke-Test 'archive evidence accepts exact existing-release verification without a rebuild claim' {
    Assert-PackageArchiveEvidence -Definition (New-ReuseEvidenceFixture)
    Assert-PackageArchiveEvidence -Definition (New-ReuseEvidenceFixture -Id 'boost-msvc')
}

Invoke-Test 'archive evidence rejects ambiguous or incomplete existing-release claims' {
    $mutations = @(
        { param($d) $d.acquisition.mode = 'unknown' },
        { param($d) $d.verification | Add-Member secondBuildSha256 ('a' * 64) },
        { param($d) $d.acquisition.sourceRelease.repository = 'other/repository' },
        { param($d) $d.acquisition.sourceRelease.releaseId = 0 },
        { param($d) $d.acquisition.sourceRelease.assetId = 0 },
        { param($d) $d.acquisition.sourceRelease.tag = '' },
        { param($d) $d.acquisition.sourceRelease.url = 'https://example.com/example.zip' },
        { param($d) $d.acquisition.sourceRelease.observedImmutable = $true },
        { param($d) $d.acquisition.sourceRelease.observedImmutable = 'false' },
        { param($d) $d.acquisition.sourceRelease.sourceStatus = 'immutable-release' },
        { param($d) $d.acquisition.task5CopyRequired = $false },
        { param($d) $d.acquisition.downloadVerification.sha256 = 'b' * 64 },
        { param($d) $d.acquisition.downloadVerification.sizeBytes = 124 },
        { param($d) $d.acquisition.downloadVerification.verifiedAt = '' },
        { param($d) $d.inputs[0].sha256 = 'b' * 64 },
        { param($d) $d.verification.offline.status = 'failed' },
        { param($d) $d.verification.offline.variants.release.runtimeExitCode = 8 },
        { param($d) $d.verification.reinstall.stateUnchanged = $false },
        { param($d) $d.id = 'host-tools' },
        { param($d) $d.id = 'cmake-sources' },
        { param($d) $d.id = 'msys2-sonosystem' },
        { param($d) $d.id = 'vcpkg-sonosystem' },
        { param($d) $d.id = 'libdatachannel' },
        { param($d) $d.acquisition.mode = 'built' },
        { param($d) $d.asset = 'another.zip'; $d.acquisition.sourceRelease.assetName = 'another.zip'; $d.inputs[0].originalFilename = 'another.zip' },
        { param($d) $d.verification.archiveSha256 = 'b' * 64; $d.acquisition.downloadVerification.sha256 = 'b' * 64; $d.inputs[0].sha256 = 'b' * 64 },
        { param($d) $d.verification.archiveSizeBytes++; $d.acquisition.downloadVerification.sizeBytes++; $d.inputs[0].sizeBytes++ },
        { param($d) $d.acquisition.sourceRelease.releaseId++ },
        { param($d) $d.acquisition.sourceRelease.assetId++ },
        { param($d) $d.provenance.rebuilt = $true },
        { param($d) $d.provenance.recompressed = $true },
        { param($d) $d.verification.buildReproducibility.performed = $true },
        { param($d) $d.provenance.rebuilt = 'false' },
        { param($d) $d.verification.offline.link = 'static' },
        { param($d) $d.verification.offline.components = @('thread') },
        { param($d) $d.verification.offline.staticLibraries.consumerTested = $true },
        { param($d) $d.verification.offline.staticLibraries.PSObject.Properties.Remove('validationStatus') },
        { param($d) $d.contents.manifest = 'other.json' },
        { param($d) $d.contents.manifestSha256 = 'b' * 64 },
        { param($d) $d.source.sha256 = 'b' * 64 },
        { param($d) $d.source.sizeBytes++ },
        { param($d) $d.installLayout.archiveRoot = '' },
        { param($d) $d.installLayout.flattenArchive = $true },
        { param($d) $d.contents.dlls = @() },
        { param($d) $d.dependencies = @() },
        { param($d) $d.closure.installationOrder = @('boost-mingw', 'msys2-sonosystem') },
        { param($d) $d.closure.runtimePathOrder = @('C:/msys64/mingw64/bin') },
        { param($d) $d.closure.runtimeDependencies = @() },
        { param($d) $d.closure.runtimeDependencies[0].version = '15.2.0-9' },
        { param($d) $d.closure.runtimeDependencies[0].sha256 = 'b' * 64 },
        { param($d) $d.closure.runtimeDependencies[0].signatureSha256 = 'b' * 64 },
        { param($d) $d.closure.runtimeDependencies[0].bundledInThisArchive = $true },
        { param($d) $d.closure.runtimeFiles = @() },
        { param($d) $d.closure.runtimeFiles[0].sha256 = 'b' * 64 }
    )
    foreach ($mutate in $mutations) {
        $definition = New-ReuseEvidenceFixture
        & $mutate $definition
        Assert-Throws -Action { Assert-PackageArchiveEvidence -Definition $definition } -MessagePattern '.+'
    }
    Write-Host "Rejected $($mutations.Count) invalid MinGW/reuse metadata cases."
}

Invoke-Test 'archive evidence requires both exact MSVC variants and actual manifests' {
    $mutations = @(
        { param($d) $d.verification.offline.variants.PSObject.Properties.Remove('debug') },
        { param($d) $d.verification.offline.variants.PSObject.Properties.Remove('release') },
        { param($d) $d.verification.offline.variants.debug.runtimeExitCode = 1 },
        { param($d) $d.verification.offline.variants.release.buildExitCode = 1 },
        { param($d) $d.verification.offline.variants | Add-Member extra ([pscustomobject]@{configureExitCode=0;buildExitCode=0;runtimeExitCode=0}) }
    )
    foreach ($mutate in $mutations) {
        $definition = New-ReuseEvidenceFixture -Id 'boost-msvc'
        & $mutate $definition
        Assert-Throws -Action { Assert-PackageArchiveEvidence -Definition $definition } -MessagePattern '.+'
    }
    $definition = New-ReuseEvidenceFixture -Id 'boost-msvc'
    Assert-Throws -Action { Assert-PackageArchiveEvidence -Definition $definition -EvidenceRoot (Join-Path $repoRoot 'missing-evidence-root') } -MessagePattern 'manifest is missing'
    Write-Host "Rejected $($mutations.Count) invalid MSVC variants and one missing-manifest case."
}

foreach ($id in @('host-tools', 'msys2-sonosystem', 'vcpkg-sonosystem', 'boost-mingw', 'boost-msvc', 'libdatachannel', 'cmake-sources')) {
    Invoke-Test "production $id has complete source, redistribution, and offline evidence" {
        $definitionPath = Join-Path $repoRoot "packages/windows/$id.json"
        $definition = & $definitionValidatorPath -DefinitionPath $definitionPath
        $definitionText = Get-Content -LiteralPath $definitionPath -Raw
        foreach ($privateMarker in @('C:\Users\', 'C:/Users/', 'Menna Rihan', 'toolchain-staging', 'MENNAR~1', 'MENNA~1')) {
            Assert-True -Condition (-not $definitionText.Contains($privateMarker, [StringComparison]::OrdinalIgnoreCase)) -Message "Definition contains private staging path marker '$privateMarker'"
        }
        Assert-Equal -Actual $definition.kind -Expected 'zip' -Message 'Production package must be a runnable ZIP'
        Assert-True -Condition (@($definition.inputs).Count -gt 0) -Message 'Source inputs are missing'
        foreach ($input in $definition.inputs) {
            foreach ($field in @('url', 'retrievedAt', 'originalFilename', 'detectedVersion', 'licenseId')) {
                Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$input.$field)) -Message "Input lacks $field"
            }
            Assert-True -Condition ([string]$input.sha256 -cmatch '^[0-9a-f]{64}$') -Message 'Input SHA-256 is missing'
            Assert-True -Condition ($input.sizeBytes -gt 0) -Message 'Input byte length is missing'
            Assert-True -Condition ($input.authenticode.status -cin @('Valid', 'NotSigned', 'NotApplicable')) -Message 'Invalid or unresolved signature'
        }
        Assert-Equal -Actual $definition.closure.status -Expected 'complete' -Message 'Dependency closure is unresolved'
        Assert-Equal -Actual $definition.redistribution.status -Expected 'permitted' -Message 'Redistribution is unresolved'
        foreach ($license in $definition.licenses) {
            $licensePath = Join-Path $repoRoot $license
            Assert-True -Condition (Test-Path -LiteralPath $licensePath -PathType Leaf) -Message "License is missing: $license"
            Assert-True -Condition ((Get-Item -LiteralPath $licensePath).Length -gt 0) -Message "License is empty: $license"
        }
        Assert-True -Condition ([string]$definition.verification.archiveSha256 -cmatch '^[0-9a-f]{64}$') -Message 'Archive evidence is missing'
        Assert-True -Condition ($definition.verification.archiveSizeBytes -gt 0) -Message 'Archive size is missing'
        Assert-PackageArchiveEvidence -Definition $definition
        Assert-Equal -Actual $definition.verification.offline.status -Expected 'passed' -Message 'Offline verification did not pass'
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$definition.verification.offline.method)) -Message 'Offline method is missing'
    }
}

Invoke-Test 'MSYS2 binary and corresponding-source archives are exact deterministic companions' {
    $path = Join-Path $repoRoot 'packages/windows/msys2-sonosystem.json'
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message 'MSYS2 package definition is missing'
    $definition = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
    Assert-Equal -Actual $definition.verification.archiveSha256 -Expected 'b027ce5144800a00fac01510c50a730498fe4c35081025548a2cc43809f2c200' -Message 'MSYS2 binary archive differs'
    Assert-Equal -Actual ([long]$definition.verification.archiveSizeBytes) -Expected 1984114092L -Message 'MSYS2 binary archive size differs'
    Assert-True -Condition ($definition.sourceCompanion.mandatoryAlongsideBinary -is [bool] -and $definition.sourceCompanion.mandatoryAlongsideBinary) -Message 'MSYS2 source companion is not mandatory'
    Assert-Equal -Actual $definition.sourceCompanion.sha256 -Expected '9aac3540884aeac5040e5ecc9fb5b248191ee1b663ef2ab4993b60bd0ec1f3e2' -Message 'MSYS2 source companion differs'
    Assert-Equal -Actual ([long]$definition.sourceCompanion.sizeBytes) -Expected 3300167861L -Message 'MSYS2 source companion size differs'
    Assert-Equal -Actual $definition.sourceCompanion.secondBuildSha256 -Expected $definition.sourceCompanion.sha256 -Message 'MSYS2 source companion rebuild differs'
    Assert-Equal -Actual ([int]$definition.contents.packageCount) -Expected 347 -Message 'MSYS2 closure count differs'
    Assert-Equal -Actual ([int]$definition.sourceCompanion.embeddedCargoCrates) -Expected 533 -Message 'MSYS2 Cargo source closure differs'
}

Write-Host "Package tests: $script:passed passed, $script:failed failed."
if ($script:failed -ne 0) { exit 1 }
