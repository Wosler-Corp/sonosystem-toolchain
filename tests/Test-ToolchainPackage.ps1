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

Write-Host "Package tests: $script:passed passed, $script:failed failed."
if ($script:failed -ne 0) { exit 1 }
