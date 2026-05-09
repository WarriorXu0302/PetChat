param(
    [string]$RunDir = '.\xinxin-run',
    [string]$AuditFile = $null,
    [string[]]$StateReview = @(),
    [string]$ManualStatus = $null,
    [string]$Reviewer = $env:USERNAME,
    [string]$Notes = $null,
    [string]$RunLogFile = $null,
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runRoot = Resolve-Path $RunDir
$qaDir = Join-Path $runRoot 'qa'
$scriptDir = Split-Path -Parent $PSCommandPath
$runLogScript = Join-Path $scriptDir 'generate-v2.1-run-log.ps1'

if (-not (Test-Path $qaDir)) {
    throw "QA directory not found: $qaDir"
}
if (-not (Test-Path $runLogScript)) {
    throw "Required helper script missing: $runLogScript"
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

function Resolve-StateReviewRows {
    param([string[]]$Rows)

    $parsed = @{}
    foreach ($row in $Rows) {
        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }
        $parts = $row -split ':', 2
        if ($parts.Count -ne 2) {
            throw "Invalid StateReview format: '$row'. Expected 'state:PASS|FAIL|PENDING'."
        }

        $state = $parts[0].Trim()
        $status = $parts[1].Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($state)) {
            throw "Invalid StateReview format: '$row'. State name is empty."
        }
        if (@('PASS', 'FAIL', 'PENDING') -notcontains $status) {
            throw "Invalid manual status '$status' in '$row'. Use PASS, FAIL or PENDING."
        }

        $parsed[$state] = $status
    }
    return $parsed
}

$auditPath = Get-LatestAuditFile -RunRoot $runRoot -ExplicitPath $AuditFile
$audit = Get-Content $auditPath -Raw | ConvertFrom-Json
if ($null -eq $audit -or $null -eq $audit.summary -or $null -eq $audit.manual_review) {
    throw 'Invalid or incomplete audit payload.'
}

if (-not ($audit.PSObject.Properties.Name -contains 'output_file')) {
    $audit | Add-Member -NotePropertyName 'output_file' -NotePropertyValue $auditPath -Force
}

$reviewInput = Resolve-StateReviewRows -Rows $StateReview
$expectedStates = @()
if ($audit.PSObject.Properties.Name -contains 'state_matrix') {
    foreach ($item in $audit.state_matrix) {
        $expectedStates += [string]$item.state
    }
}
if ($expectedStates.Count -eq 0 -and $audit.PSObject.Properties.Name -contains 'status') {
    if ($audit.status.PSObject.Properties.Name -contains 'checks' -and $audit.status.checks.PSObject.Properties.Name -contains 'frames') {
        foreach ($item in $audit.status.checks.frames) {
            $expectedStates += [string]$item.state
        }
    }
}

foreach ($state in $reviewInput.Keys) {
    if ($expectedStates.Count -gt 0 -and -not ($expectedStates -contains $state)) {
        throw "State '$state' does not appear in audit.state_matrix. Expected one of: $($expectedStates -join ', ')"
    }
}

$existingStates = @{}
if ($audit.manual_review.PSObject.Properties.Name -contains 'state_reviews') {
    foreach ($item in $audit.manual_review.state_reviews) {
        if ($null -ne $item.state) {
            $existingStates[[string]$item.state] = $item
        }
    }
}

$updatedAt = [DateTime]::UtcNow.ToString('o')
$stateReviews = @()
$orderedStates = if ($expectedStates.Count -gt 0) {
    $expectedStates
} else {
    $reviewInput.Keys | Sort-Object
}

foreach ($state in $orderedStates) {
    if ($reviewInput.ContainsKey($state)) {
        $stateReviews += [ordered]@{
            state = $state
            status = $reviewInput[$state]
            reviewed_by = $Reviewer
            reviewed_at = $updatedAt
            notes = ''
        }
    } elseif ($existingStates.ContainsKey($state)) {
        $stateReviews += $existingStates[$state]
    } else {
        $stateReviews += [ordered]@{
            state = $state
            status = 'PENDING'
            reviewed_by = $Reviewer
            reviewed_at = $updatedAt
            notes = ''
        }
    }
}

foreach ($state in $reviewInput.Keys) {
    if ($stateReviews.state -notcontains $state) {
        $stateReviews += [ordered]@{
            state = $state
            status = $reviewInput[$state]
            reviewed_by = $Reviewer
            reviewed_at = $updatedAt
            notes = ''
        }
    }
}

$manualStatuses = @($stateReviews | ForEach-Object { [string]$_.status })
$computedManual = if ($manualStatuses.Count -eq 0) {
    'PENDING'
} elseif ($manualStatuses -contains 'FAIL') {
    'FAIL'
} elseif ($manualStatuses -contains 'PENDING') {
    'PENDING'
} else {
    'PASS'
}

if ($ManualStatus) {
    $ManualStatus = $ManualStatus.ToUpperInvariant()
    if (@('PASS', 'FAIL', 'PENDING') -notcontains $ManualStatus) {
        throw "Invalid -ManualStatus '$ManualStatus'. Use PASS, FAIL or PENDING."
    }
    $computedManual = $ManualStatus
}

$audit.manual_review = [ordered]@{
    status = $computedManual
    contact_sheet = if ($audit.manual_review.PSObject.Properties.Name -contains 'contact_sheet') { $audit.manual_review.contact_sheet } else { (Test-Path (Join-Path $qaDir 'contact-sheet.png')) }
    review_sheet = if ($audit.manual_review.PSObject.Properties.Name -contains 'review_sheet') { $audit.manual_review.review_sheet } else { (Test-Path (Join-Path $qaDir 'review.json')) }
    notes = if ($Notes) { $Notes } elseif ($audit.manual_review.PSObject.Properties.Name -contains 'notes') { $audit.manual_review.notes } else { '' }
    reviewer = $Reviewer
    reviewed_at = $updatedAt
    state_reviews = $stateReviews
}

if (-not $NoWrite) {
    $audit | ConvertTo-Json -Depth 10 | Set-Content -Path $auditPath -Encoding utf8
}

$updatedRunLog = $null
if (-not $NoWrite) {
    $updatedRunLog = & $runLogScript -RunDir $runRoot -AuditData $audit -OutputFile $RunLogFile -Executor $Reviewer -NoWrite:$false
}

[ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    run_dir = $runRoot.Path
    audit_file = $auditPath
    reviewer = $Reviewer
    manual_review = $audit.manual_review.status
    state_reviews = $stateReviews
    run_log = if ($updatedRunLog) { $updatedRunLog.output_file } else { $RunLogFile }
}
