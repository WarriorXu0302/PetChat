param(
    [string]$RunDir = '.\xinxin-run',
    [string]$AuditFile = $null,
    [string]$OutputFile = $null,
    [switch]$RequirePass,
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runRoot = Resolve-Path $RunDir
$qaDir = Join-Path $runRoot 'qa'

if (-not (Test-Path $qaDir)) {
    throw "QA directory not found: $qaDir"
}

function Get-LatestAuditFile {
    param([string]$RunRoot, [string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) {
            throw "Audit file not found: $ExplicitPath"
        }
        return (Resolve-Path $ExplicitPath).Path
    }

    $candidates = @(Get-ChildItem -Path (Join-Path $RunRoot 'qa') -File -Filter 'run-audit-*.json' | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        throw "No run-audit-*.json found in $RunRoot\\qa. Run audit first or pass -AuditFile."
    }
    return $candidates[0].FullName
}

$auditPath = Get-LatestAuditFile -RunRoot $runRoot -ExplicitPath $AuditFile
$audit = Get-Content $auditPath -Raw | ConvertFrom-Json

if ($null -eq $audit -or $null -eq $audit.summary -or $null -eq $audit.manual_review) {
    throw "Invalid or incomplete audit payload: $auditPath"
}

$reasons = @()
if ($audit.summary.overall -ne 'PASS') {
    $reasons += "audit.overall is '$($audit.summary.overall)'."
}

$manualStatus = if ($audit.manual_review.PSObject.Properties.Name -contains 'status') {
    [string]$audit.manual_review.status
} else {
    'PENDING'
}
if ($manualStatus -ne 'PASS') {
    $reasons += "manual_review.status is '$manualStatus'."
}

if ($audit.PSObject.Properties.Name -contains 'status' -and $audit.status.PSObject.Properties.Name -contains 'gate') {
    if ($audit.status.gate.ready_for_generation -ne $true) {
        $reasons += 'pipeline gate.ready_for_generation is false.'
    }
}

$ready = $reasons.Count -eq 0
$decision = if ($ready) { 'PASS' } else { 'BLOCKED' }
$gate = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    run_dir = $runRoot.Path
    audit_file = $auditPath
    overall = $audit.summary.overall
    manual_review = $manualStatus
    ready_for_generation = if ($audit.PSObject.Properties.Name -contains 'status' -and $audit.status.PSObject.Properties.Name -contains 'gate') {
        $audit.status.gate.ready_for_generation
    } else {
        $false
    }
    decision = $decision
    blockers = $reasons
}

if (-not $NoWrite) {
    if (-not (Test-Path $qaDir)) {
        New-Item -ItemType Directory -Path $qaDir -Force | Out-Null
    }
    if (-not $OutputFile) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $OutputFile = Join-Path $qaDir ('release-gate-{0}.json' -f $timestamp)
    }
    $gate | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding utf8
}

if ($RequirePass -and -not $ready) {
    throw "Release gate blocked: $($reasons -join '; ')"
}

if ($ready) {
    Write-Host "release_gate=PASS"
} else {
    Write-Host "release_gate=BLOCKED"
}

$gate
