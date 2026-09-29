[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SonoBotRoot,
    [string]$InventoryPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog/windows/dependency-inventory.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read-only coverage gate. Never execute the inspected setup/build commands.
# Task 3 validates acquisition-site classification and approved dispositions.
# Task 4 proves dependency closure; Task 8 migrates the recorded source sites.
$failures = [Collections.Generic.List[string]]::new()
$findings = [Collections.Generic.List[object]]::new()
function Fail([string]$Message) { $failures.Add($Message) }
function Add-Finding([string]$Path, [int]$Line, [string]$Kind, [string]$Text) {
    $findings.Add([pscustomobject]@{ path = $Path; line = $Line; kind = $Kind; text = $Text.Trim() })
}
function Scan-Lines([string]$Path, [string[]]$Lines, [int]$Start, [int]$End) {
    for ($i = $Start; $i -lt $End; $i++) {
        $text = $Lines[$i].Trim()
        if ($text -match '^(#|REM\b|::|echo\b|where\b|message\s*\()') { continue }
        $kind = $null
        if ($text -match '^uses:\s*[^./]') { $kind = 'github-action' }
        elseif ($text -match 'github\.rest\.|\bgh\s+api\b') { $kind = 'service' }
        elseif ($text -match '\bFetchContent_(Declare|Populate)\s*\(') { $kind = 'fetch-content' }
        elseif ($text -match '\b(Invoke-WebRequest|Invoke-RestMethod|curl|wget|bitsadmin)\b|\.DownloadFile\(') { $kind = 'network' }
        elseif ($text -match '(\bgit\b|%GIT_EXE%).*\b(clone|fetch|submodule\s+update)\b') { $kind = 'git' }
        elseif ($text -match 'pacman.*\s-S|\b(pip|pip3)\s+install\b|\b(choco|winget|nuget)\s+(install|upgrade|source)\b') { $kind = 'package-manager' }
        elseif ($text -match '^call\s+.*bootstrap-vcpkg\.bat|vcpkg(?:\.exe)?["\s]+install\b') { $kind = 'vcpkg' }
        elseif ($text -match '^PowerShell\b.*-File\s+"%TOOLCHAIN_INSTALLER%"') { $kind = 'boost-installer' }
        if ($kind) { Add-Finding $Path ($i + 1) $kind $text }
    }
}

if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
    Write-Host 'FAIL: authoritative Windows dependency inventory is missing'
    exit 1
}
$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json -Depth 100
$actualCommit = (& git -C $SonoBotRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $inventory.source.commit) {
    Fail "Source revision mismatch: expected $($inventory.source.commit), observed $actualCommit"
}
$sourceChanges = @(& git -C $SonoBotRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $sourceChanges.Count -ne 0) { Fail 'SonoBot must be a clean, read-only evidence checkout' }

# Select literal Windows jobs by YAML indentation; unresolved runner expressions
# fail closed. Linux-only Review Helper pip commands are not Windows acquisitions.
$workflowRoot = Join-Path $SonoBotRoot '.github/workflows'
foreach ($file in Get-ChildItem -LiteralPath $workflowRoot -File | Where-Object Extension -In '.yml', '.yaml') {
    $path = '.github/workflows/' + $file.Name
    $lines = @(Get-Content -LiteralPath $file.FullName)
    $jobs = @($i = 0; foreach ($line in $lines) { if ($line -match '^  [\w-]+:\s*$') { $i }; $i++ })
    for ($j = 0; $j -lt $jobs.Count; $j++) {
        $start = $jobs[$j]
        $end = if ($j + 1 -lt $jobs.Count) { $jobs[$j + 1] } else { $lines.Count }
        $runners = @($lines[$start..($end - 1)] | Where-Object { $_ -match '^    runs-on:' })
        if ($runners.Count -eq 0) {
            if (($lines[$start..($end - 1)] -join "`n") -match '(?m)^    uses:') { Fail "Uninspected reusable workflow: ${path}:$($start + 1)" }
            continue
        }
        if (($runners -join '') -match '\$\{\{') { Fail "Unresolved workflow runner: ${path}:$($start + 1)"; continue }
        if (($runners -join '') -match 'windows') { Scan-Lines $path $lines $start $end }
    }
}
foreach ($path in @('setup_dependencies.bat', 'install-from-wosler-repo.ps1', 'CMakeLists.txt')) {
    $lines = @(Get-Content -LiteralPath (Join-Path $SonoBotRoot $path))
    Scan-Lines $path $lines 0 $lines.Count
}

$allowedCategories = @('package', 'licensed-runner-prerequisite', 'github-action-full-sha', 'retained-service-call', 'excluded-deployment-only', 'license-blocked')
foreach ($finding in $findings) {
    $key = "$($finding.path):$($finding.line)"
    $mappings = @($inventory.mappings | Where-Object {
        @($_.sources | Where-Object { $_.path -ceq $finding.path -and $_.line -eq $finding.line }).Count -gt 0
    })
    if ($mappings.Count -ne 1) { Fail "${key}: expected exactly one mapping, observed $($mappings.Count) [$($finding.kind)]"; continue }
    $mapping = $mappings[0]
    if (@($mapping.sources | Where-Object { $_.path -ceq $finding.path -and $_.line -eq $finding.line }).Count -ne 1) {
        Fail "${key}: duplicate source mapping"
    }
    if ($mapping.category -notin $allowedCategories) { Fail "${key}: unknown category $($mapping.category)" }
    if ([string]::IsNullOrWhiteSpace($mapping.purpose)) { Fail "${key}: mapping purpose missing" }
    if ($finding.kind -eq 'github-action') {
        if ($mapping.category -ne 'github-action-full-sha' -or $mapping.desiredCommit -notmatch '^[a-f0-9]{40}$') {
            Fail "${key}: desired action pin must be a full commit SHA"
        }
        if ($finding.text -cne "uses: $($mapping.observedRef)" -or $mapping.sourceRef -cne "refs/tags/$($mapping.observedRef.Split('@')[1])") {
            Fail "${key}: action source reference does not match observed code"
        }
        $officialRepository = 'https://github.com/' + $mapping.observedRef.Split('@')[0] + '.git'
        if ($mapping.resolvedFrom -cne $officialRepository -or $mapping.migrationTask -ne 8 -or $mapping.currentlyFullShaPinned) {
            Fail "${key}: official ref provenance or pending Task 8 migration missing"
        }
    }
    if ($mapping.category -eq 'package') {
        $packageIds = @($mapping.packageIds)
        if ($packageIds.Count -eq 0 -or @($packageIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { Fail "${key}: package ID missing" }
        if (@($packageIds | Select-Object -Unique).Count -ne $packageIds.Count) { Fail "${key}: duplicate package IDs" }
    }
    if ($mapping.category -eq 'excluded-deployment-only') {
        if ($mapping.profileMembership.Count -ne 0 -or -not $mapping.currentlyReachableFromSetup -or $mapping.migrationTask -ne 8 -or [string]::IsNullOrWhiteSpace($mapping.requiredMigration)) {
            Fail "${key}: exclusion must record current setup reachability, no profile membership, and Task 8 gating"
        }
    }
    if ($mapping.category -eq 'license-blocked') {
        if ($mapping.status -ne 'license-blocked' -or $mapping.upstreamFallbackAllowed -or $mapping.packageIds.Count -ne 0 -or $null -ne $mapping.redistributionEvidence) {
            Fail "${key}: license-blocked acquisition must not define a package, approval, or vendor fallback"
        }
    }
}
foreach ($mapping in $inventory.mappings) {
    foreach ($source in $mapping.sources) {
        if (@($findings | Where-Object { $_.path -ceq $source.path -and $_.line -eq $source.line }).Count -ne 1) {
            Fail "Stale or ambiguous mapping: $($source.path):$($source.line)"
        }
    }
}

if ($inventory.status -ne 'acquisition-sites-classified') { Fail 'Task 3 acquisition-site classification is incomplete' }
if ($findings.Count -ne $inventory.expectedSiteCount) { Fail "Expected $($inventory.expectedSiteCount) independently inventoried sites, observed $($findings.Count)" }
if ($inventory.closure.status -ne 'deferred-to-task-4' -or $inventory.closure.complete -or $inventory.closure.requiredEvidence.Count -lt 3) {
    Fail 'Task 4 closure must remain explicitly deferred with evidence requirements'
}
foreach ($id in @('msys2', 'vcpkg', 'libdatachannel')) {
    if (@($inventory.closure.requiredEvidence | Where-Object id -eq $id).Count -ne 1) { Fail "Task 4 requires exactly one evidence specification for $id" }
}
foreach ($disposition in @(@{ id = 'cp210x'; category = 'license-blocked' }, @{ id = 'inno-setup'; category = 'excluded-deployment-only' })) {
    $entries = @($inventory.mappings | Where-Object id -eq $disposition.id)
    if ($entries.Count -ne 1 -or $entries[0].category -ne $disposition.category) { Fail "Approved disposition missing for $($disposition.id)" }
}
foreach ($requirement in $inventory.closure.requiredEvidence) {
    if ($requirement.status -ne 'deferred-to-task-4' -or $requirement.sources.Count -eq 0 -or $requirement.mustCollect.Count -eq 0) {
        Fail "Missing Task 4 evidence requirements: $($requirement.id)"
    }
}
$libdatachannel = @($inventory.mappings | Where-Object id -eq 'libdatachannel')
if ($libdatachannel.Count -ne 1 -or $libdatachannel[0].authoritativeVersion -ne '0.21.2' -or $libdatachannel[0].packageIds.Count -ne 1) {
    Fail 'Exactly one authoritative libdatachannel 0.21.2 package is required'
} else {
    $staleVariants = @($libdatachannel[0].variants | Where-Object observedVersion -eq 'v0.19.5')
    if ($staleVariants.Count -ne 1 -or $staleVariants[0].status -ne 'stale-migrate-task-8' -or $staleVariants[0].packageVersion -ne '0.21.2') {
        Fail 'Backup libdatachannel 0.19.5 must target the authoritative package in Task 8'
    }
}
Write-Host "Scanned $($findings.Count) executable acquisition/service sites; failures: $($failures.Count)"
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
if ($failures.Count -gt 0) { exit 1 }
Write-Host "PASS: $($findings.Count)/$($inventory.expectedSiteCount) acquisition sites classified exactly once; closure deferred to Task 4; source migrations recorded for Task 8"
