param(
    [string]$RootDir = (Get-Location).Path,
    [switch]$IncludeAllRuns,
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$collectScript = Join-Path $scriptDir 'collect-pet-run-status.ps1'

$root = Resolve-Path $RootDir
$runDirs = if ($IncludeAllRuns) {
    @(
        Get-ChildItem -Path $root -Directory |
            Where-Object { $_.Name -match '-run$' } |
            Sort-Object Name
    )
} else {
    @(
        Get-ChildItem -Path $root -Directory |
        Where-Object { $_.Name -eq 'xinxin-run' } |
        Sort-Object Name
    )
}

if (-not $IncludeAllRuns -and $runDirs.Count -eq 0) {
    Write-Warning "xinxin-run was not found in '$RootDir'. Falling back to scanning all *-run directories."
    $runDirs = @(
        Get-ChildItem -Path $root -Directory |
            Where-Object { $_.Name -match '-run$' } |
            Sort-Object Name
    )
}

$manifest = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    root = $root.Path
    run_scope = if ($IncludeAllRuns) { 'all-runs' } else { 'xinxin-only' }
    warnings = @()
    runs = @()
}

foreach ($run in $runDirs) {
    $status = & $collectScript -RunDir $run.FullName -NoWrite
    $manifest.runs += [ordered]@{
        run_dir = $status.run_dir
        pet_id = $status.pet_id
        state = $status.state
        readiness_score = $status.summary.readiness_score
        frame_completion_ratio = $status.summary.frame_completion_ratio
        jobs_completion_ratio = $status.summary.jobs_completion_ratio
        issues = $status.issues.Count
        warnings = $status.warnings.Count
        jobs = $status.jobs
        summary = $status.summary
        gate = $status.gate
    }
}

if ($runDirs.Count -eq 0) {
    $manifest.warnings += 'No run directories matched the current scope.'
}

if (-not $NoWrite) {
    $out = Join-Path $root 'pipeline-manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $out -Encoding utf8
}

$manifest
