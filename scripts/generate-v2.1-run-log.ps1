param(
    [string]$RunDir = '.\xinxin-run',
    [string]$AuditFile = $null,
    [psobject]$AuditData = $null,
    [string]$OutputFile = $null,
    [string]$SummaryFile = $null,
    [string]$Executor = 'Codex',
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runRoot = Resolve-Path $RunDir
$qaDir = Join-Path $runRoot 'qa'

if (-not (Test-Path $qaDir)) {
    if ($NoWrite) {
        throw "QA directory not found: $qaDir"
    }
    New-Item -ItemType Directory -Path $qaDir -Force | Out-Null
}

$audit = $null
if ($null -ne $AuditData) {
    $audit = $AuditData
} elseif ($AuditFile) {
    if (-not (Test-Path $AuditFile)) {
        throw "Audit file not found: $AuditFile"
    }
    $sourceAuditFile = (Resolve-Path $AuditFile).Path
    $audit = Get-Content $AuditFile -Raw | ConvertFrom-Json
    if (-not ($audit.PSObject.Properties.Name -contains 'output_file')) {
        $audit | Add-Member -NotePropertyName 'output_file' -NotePropertyValue $sourceAuditFile -Force
    }
} else {
    $candidates = @(Get-ChildItem -Path $qaDir -File -Filter 'run-audit-*.json' | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        throw "No run-audit-*.json found in $qaDir. Run audit first or pass -AuditFile."
    }
    $sourceAuditFile = $candidates[0].FullName
    $audit = Get-Content $sourceAuditFile -Raw | ConvertFrom-Json
    if (-not ($audit.PSObject.Properties.Name -contains 'output_file')) {
        $audit | Add-Member -NotePropertyName 'output_file' -NotePropertyValue $sourceAuditFile -Force
    }
}

if ($null -eq $audit -or $null -eq $audit.summary) {
    throw 'Invalid or empty audit payload.'
}

if (-not $OutputFile) {
    $runLogTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputFile = Join-Path $qaDir ('run-log-{0}.md' -f $runLogTimestamp)
} else {
    $runLogBaseName = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
    $runLogTimestamp = if ($runLogBaseName -match 'run-log-(\d{8}-\d{6})') {
        $Matches[1]
    } else {
        Get-Date -Format 'yyyyMMdd-HHmmss'
    }
}

if (-not $SummaryFile) {
    $SummaryFile = Join-Path $qaDir ('run-log-{0}-summary.json' -f $runLogTimestamp)
}

$stateRows = @()
if ($null -ne $audit.state_matrix) {
    foreach ($s in ($audit.state_matrix | Sort-Object state)) {
        $stateRows += ('- {0}: {1} ({2}/{3} frames)' -f $s.state, $s.status, $s.actual_frames, $s.expected_frames)
    }
} else {
    $stateRows += '- idle: PENDING'
}

$checksRows = @()
if ($null -ne $audit.checks) {
    foreach ($c in $audit.checks) {
        $checksRows += ('- {0}: {1} - {2}' -f $c.name, $c.status, $c.message)
    }
} else {
    $checksRows += '- no check entries found'
}

$decision = if ($audit.summary.overall -eq 'PASS' -and $audit.manual_review.status -eq 'PASS') {
    'PASS'
} elseif ($audit.summary.overall -eq 'PASS' -and $audit.manual_review.status -eq 'PENDING') {
    'RE-TRY'
} else {
    'RE-TRY'
}

$decisionNote = if ($audit.summary.overall -ne 'PASS') {
    'Automatic audit failed. Fix failures before release.'
} elseif ($audit.manual_review.status -eq 'PENDING') {
    'Automatic audit passed, but manual review is still required.'
} else {
    'Automatic audit passed and manual review passed.'
}

$lines = @(
    '# Run Log - xinxin v2.1 (auto-generated)',
    '',
    '## Basic Info',
    ('- Run Time: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('- Executor: {0}' -f $Executor),
    '- Target: xinxin-persona-v2.1',
    ('- JSON snapshot: {0}' -f (Split-Path $SummaryFile -Leaf)),
    '- Trigger:',
    '  - [x] automated pre-check and delivery audit bundle',
    '',
    '## Execution',
    '1) collect-pet-run-status.ps1',
    '2) build-xinxin-delivery-manifest.ps1',
    '3) audit-xinxin-v2.1.ps1',
    ('4) generated audit: {0}' -f $audit.output_file),
    ('5) generated run log: {0}' -f (Split-Path $OutputFile -Leaf)),
    '',
    '## Auto audit summary',
    ('- overall: {0}' -f $audit.summary.overall),
    ('- pass_checks: {0}, warn_checks: {1}, fail_checks: {2}' -f $audit.summary.pass_checks, $audit.summary.warn_checks, $audit.summary.fail_checks),
    ('- manual_review.status: {0}' -f $audit.manual_review.status),
    '',
    '## Decision',
    ('- Result: {0}' -f $decision),
    ('- Note: {0}' -f $decisionNote),
    '',
    '## Risk / Note',
    ('- audit_file: {0}' -f $audit.output_file),
    ('- visual_review_required: {0}' -f $audit.manual_review.status),
    '',
    '- [ ] Fill manual PASS/FAIL for each state after visual review'
)

$lines += '### check items'
$lines += $checksRows
$lines += ''
$lines += '### state matrix'
$lines += $stateRows

$checkMatrix = @()
if ($null -ne $audit.checks) {
    foreach ($c in $audit.checks) {
        $checkMatrix += [ordered]@{
            name = $c.name
            status = $c.status
            severity = $c.severity
            message = $c.message
        }
    }
} else {
    $checkMatrix += [ordered]@{
        name = 'checks'
        status = 'PENDING'
        severity = 'low'
        message = 'no checks captured'
    }
}

$stateMatrixPayload = @()
if ($null -ne $audit.state_matrix) {
    foreach ($s in ($audit.state_matrix | Sort-Object state)) {
        $stateMatrixPayload += [ordered]@{
            state = $s.state
            status = $s.status
            expected_frames = $s.expected_frames
            actual_frames = $s.actual_frames
            message = $s.message
        }
    }
} else {
    $stateMatrixPayload += [ordered]@{
        state = 'idle'
        status = 'PENDING'
        expected_frames = 0
        actual_frames = 0
        message = 'state_matrix missing'
    }
}

$runLogPayload = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    run_dir = $runRoot.Path
    executor = $Executor
    target = 'xinxin-persona-v2.1'
    audit_file = $audit.output_file
    output_file = $OutputFile
    summary_file = $SummaryFile
    decision = $decision
    summary = [ordered]@{
        overall = $audit.summary.overall
        pass_checks = $audit.summary.pass_checks
        warn_checks = $audit.summary.warn_checks
        fail_checks = $audit.summary.fail_checks
        manual_review = $audit.manual_review.status
        state_count = $stateMatrixPayload.Count
    }
    checks = $checkMatrix
    state_matrix = $stateMatrixPayload
    manual_review = [ordered]@{
        status = $audit.manual_review.status
        state_reviews = if ($audit.manual_review.PSObject.Properties.Name -contains 'state_reviews') {
            @($audit.manual_review.state_reviews)
        } else {
            @()
        }
        notes = if ($audit.manual_review.PSObject.Properties.Name -contains 'notes') {
            $audit.manual_review.notes
        } else {
            ''
        }
    }
}

if (-not $NoWrite) {
    $content = [string]::Join("`r`n", $lines)
    $content | Set-Content -Path $OutputFile -Encoding utf8
    $runLogPayload | ConvertTo-Json -Depth 10 | Set-Content -Path $SummaryFile -Encoding utf8
}

[ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    run_dir = $runRoot.Path
    output_file = $OutputFile
    summary_file = $SummaryFile
    executor = $Executor
    summary = [ordered]@{
        overall = $audit.summary.overall
        decision = $decision
        pass_checks = $audit.summary.pass_checks
        warn_checks = $audit.summary.warn_checks
        fail_checks = $audit.summary.fail_checks
        manual_review = $audit.manual_review.status
        state_count = $stateRows.Count
    }
}
