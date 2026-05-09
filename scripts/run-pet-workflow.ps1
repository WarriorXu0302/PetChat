param(
    [string]$RunDir = '.\\xinxin-run',

    [switch]$CreateStructure,

    [switch]$NoStatusWrite,

    [switch]$RequireHealthy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$collectScript = Join-Path $scriptDir 'collect-pet-run-status.ps1'

if (-not (Test-Path $RunDir)) {
    throw "Run directory '$RunDir' not found. Default is .\\xinxin-run. You can pass -RunDir .\\xinxin-run explicitly."
}

$runRoot = Resolve-Path $RunDir
$runStates = @(
    'idle',
    'running-right',
    'running-left',
    'waving',
    'jumping',
    'failed',
    'waiting',
    'running',
    'review'
)

if ($CreateStructure) {
    $required = @('decoded', 'frames', 'final', 'qa', 'references', 'prompts', 'prompts\rows')
    foreach ($d in $required) {
        $path = Join-Path $runRoot $d
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-Host "[create] $d"
        }
    }

    foreach ($state in $runStates) {
        $stateDir = Join-Path (Join-Path $runRoot 'frames') $state
        if (-not (Test-Path $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            Write-Host "[create] frames\$state"
        }
    }
}

$status = & $collectScript -RunDir $runRoot -NoWrite:$NoStatusWrite

Write-Host "Run directory: $($status.run_dir)"
Write-Host "State: $($status.state)"
Write-Host "Jobs: complete=$($status.jobs.complete) pending=$($status.jobs.pending) failed=$($status.jobs.failed)"

if (-not $status.checks.assets['canonical_identity_ref']) {
    Write-Warning "Canonical identity image is missing; row jobs may not be valid yet."
}

if ($status.issues.Count -gt 0) {
    Write-Host "`nIssues:"
    $status.issues | ForEach-Object { Write-Host "- $($_.type): $($_.message)" }
}

if ($status.warnings.Count -gt 0) {
    Write-Host "`nWarnings:"
    $status.warnings | ForEach-Object { Write-Host "- $($_.type): $($_.message)" }
}

Write-Host "`nExecution guidance:"
if ($status.state -eq 'healthy') {
    Write-Host "- Pipeline status is healthy. You can proceed to generate or re-run image jobs."
    Write-Host "- Outputs are expected under decoded/, frames/, final/."
} else {
    Write-Host "- Pipeline is blocked or partially ready. Please resolve issues above before generation."
    Write-Host "- Once canonical/frames are ready, rerun this script to refresh run-status.json."
}

if ($RequireHealthy -and $status.state -ne 'healthy') {
    throw "Run is not healthy. Use '-RequireHealthy' only in contexts requiring zero issues and zero warnings."
}

return $status
