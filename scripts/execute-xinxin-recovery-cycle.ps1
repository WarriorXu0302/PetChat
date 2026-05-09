param(
    [string]$RunDir = '.\xinxin-run',
    [string]$RunIdPrefix = 'recovery-cycle',
    [string]$OutputRoot = '.\xinxin-run\qa\recovery-cycles',
    [string]$BundleName = '',
    [string]$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss'),
    [string]$CycleReportPath = '',
    [string]$CycleMarkdownPath = '',
    [ValidateSet('baseline', 'gate', 'all')]
    [string[]]$OnlyPhases = @(),
    [switch]$StopOnFail,
    [switch]$Force,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$runLineScript = Join-Path $scriptDir 'run-xinxin-v2.1-release-line.ps1'
$summarizeScript = Join-Path $scriptDir 'summarize-xinxin-recovery.ps1'
$resolveScript = Join-Path $scriptDir 'resolve-xinxin-next-action.ps1'

foreach ($path in @($runLineScript, $summarizeScript, $resolveScript)) {
    if (-not (Test-Path $path)) {
        throw "Required script missing: $path"
    }
}

$runRoot = Resolve-Path $RunDir -ErrorAction Stop
$runRootPath = $runRoot.Path

function Get-SafeToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    return ($Value -replace '[\\/:*?"<>|\s]+', '_')
}

$safeRunIdPrefix = Get-SafeToken $RunIdPrefix
$safeRunId = Get-SafeToken $RunId
$cycleStamp = if ([string]::IsNullOrWhiteSpace($safeRunId)) { Get-Date -Format 'yyyyMMdd-HHmmss' } else { $safeRunId }
$safeBaseName = if ($safeRunIdPrefix) { "$safeRunIdPrefix-$cycleStamp" } else { "recovery-cycle-$cycleStamp" }

$repoRoot = Split-Path -Parent $scriptDir
$cycleRoot = if ([System.IO.Path]::IsPathRooted($OutputRoot)) {
    $OutputRoot
} else {
    Join-Path $repoRoot $OutputRoot
}
if (-not [string]::IsNullOrWhiteSpace($BundleName)) {
    $cycleRoot = Join-Path $cycleRoot $BundleName
}

$bundleRoot = Join-Path $cycleRoot $safeBaseName
if (Test-Path $bundleRoot -and -not $Force) {
    throw "Recovery-cycle output root already exists: $bundleRoot; use -Force to reuse."
}
New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null

$cycleReport = if ([string]::IsNullOrWhiteSpace($CycleReportPath)) {
    Join-Path $bundleRoot 'recovery-cycle-report.json'
} else {
    $CycleReportPath
}
$cycleMarkdown = if ([string]::IsNullOrWhiteSpace($CycleMarkdownPath)) {
    Join-Path $bundleRoot 'recovery-cycle-summary.md'
} else {
    $CycleMarkdownPath
}
$cycleDigestPath = Join-Path $bundleRoot 'recovery-cycle-digest.json'
$cycleDigestMarkdownPath = Join-Path $bundleRoot 'recovery-cycle-digest.md'
$nextActionPath = Join-Path $bundleRoot 'next-action-recommendation.md'

$defaultPhases = @('baseline', 'gate', 'all')
$requestedPhases = if ($OnlyPhases -and $OnlyPhases.Count -gt 0) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($phase in $OnlyPhases) {
        $null = $set.Add($phase)
    }
    $defaultPhases | Where-Object { $set.Contains($_) }
} else {
    $defaultPhases
}

if (-not $requestedPhases -or $requestedPhases.Count -eq 0) {
    throw 'No valid phases specified for -OnlyPhases.'
}

$phaseResults = New-Object System.Collections.Generic.List[object]
$overallFail = $false
$nextActionSummary = $null

foreach ($phase in $requestedPhases) {
    $phaseBundle = Join-Path $bundleRoot $phase
    New-Item -ItemType Directory -Path $phaseBundle -Force | Out-Null

    $result = [ordered]@{
        line = $phase
        pass = $false
        output_bundle = $phaseBundle
        report = Join-Path $phaseBundle 'release-line-report.json'
        run_log = Join-Path $phaseBundle 'run-log.md'
        run_log_summary = Join-Path $phaseBundle 'run-log-summary.json'
        release_gate = Join-Path $phaseBundle 'release-gate.json'
        pipeline_status = Join-Path $phaseBundle 'pipeline-status.json'
        next_action_collect = Join-Path $phaseBundle 'next-action-collect.json'
        remediation_plan = Join-Path $phaseBundle 'remediation-plan.json'
        remediation_plan_markdown = Join-Path $phaseBundle 'remediation-plan.md'
        next_action_recommendation = Join-Path $phaseBundle 'next-action-recommendation.md'
        recovery_digest = Join-Path $phaseBundle 'recovery-digest.json'
        recovery_digest_markdown = Join-Path $phaseBundle 'recovery-digest.md'
        summary_message = ''
        gate_pass = $null
        health_status = 'unknown'
        health_score = 0
        needs_attention = $false
        failure_hints = @()
    }

    $runArgs = @(
        '-Line', $phase,
        '-RunDir', $runRootPath,
        '-RunIdPrefix', $safeRunIdPrefix,
        '-OutputBundleDir', $phaseBundle,
        '-NoFail'
    )

    try {
        Write-Host "=== phase: $phase ==="
        $null = & $runLineScript @runArgs
        if (Test-Path $result.report) {
            $report = Get-Content -Raw $result.report | ConvertFrom-Json
            $result.pass = if ($report.summary -and $null -ne $report.summary.pass) { [bool]$report.summary.pass } else { $false }
            $result.summary_message = if ($report.summary -and $report.summary.message) { [string]$report.summary.message } else { '' }
            $result.gate_pass = if ($report.summary -and $null -ne $report.summary.gate_pass) { [bool]$report.summary.gate_pass } else { $null }
            $result.health_status = if ($report.health_status) { [string]$report.health_status } else { 'unknown' }
            $result.health_score = if ($null -ne $report.health_score) { [int]$report.health_score } else { 0 }
            $result.needs_attention = if ($null -ne $report.needs_attention) { [bool]$report.needs_attention } else { $false }
            if ($report.failure_hints) {
                $result.failure_hints = @($report.failure_hints)
            }
        } else {
            $result.pass = $false
            $result.summary_message = "release-line report missing: $($result.report)"
            $result.failure_hints = @($result.summary_message)
            $overallFail = $true
        }
    } catch {
        $result.pass = $false
        $result.summary_message = $_.Exception.Message
        $result.failure_hints = @("phase failed to execute: $($_.Exception.Message)")
        $overallFail = $true
    }

    $phaseResults.Add([pscustomobject]$result)

    if (-not $result.pass) {
        $overallFail = $true
        if ($StopOnFail) {
            Write-Host "StopOnFail enabled, stop after failing phase: $phase"
            break
        }
    }
}

$allPhase = $phaseResults | Where-Object { $_.line -eq 'all' } | Select-Object -First 1
$primaryPhase = if ($allPhase) { $allPhase } else { $phaseResults | Select-Object -Last 1 }

$allReportPath = if ($primaryPhase) { $primaryPhase.report } else { '' }
$allStatusPath = if ($primaryPhase) { $primaryPhase.pipeline_status } else { '' }
$allReleaseGatePath = if ($primaryPhase) { $primaryPhase.release_gate } else { '' }
$hasReleaseGate = (-not [string]::IsNullOrWhiteSpace($allReleaseGatePath)) -and (Test-Path $allReleaseGatePath)

if ($allPhase -and (Test-Path $allReportPath)) {
    try {
        & $summarizeScript `
            -ReportPath $allReportPath `
            -RunDir $runRootPath `
            -RunIdPrefix $safeRunIdPrefix `
            -OutputPath $cycleDigestPath `
            -MarkdownOutputPath $cycleDigestMarkdownPath | Out-Null
    } catch {
        $overallFail = $true
        $primaryPhase.failure_hints += "failed to build cycle digest: $($_.Exception.Message)"
    }

    try {
        $resolverArgs = @(
            '-ReportPath', $allReportPath,
            '-RunDir', $runRootPath,
            '-RunIdPrefix', $safeRunIdPrefix,
            '-MarkdownOutputPath', $nextActionPath
        )
        if (Test-Path $allStatusPath) {
            $resolverArgs += '-RunStatusPath'
            $resolverArgs += $allStatusPath
        }
        if ($hasReleaseGate) {
            $resolverArgs += '-ReleaseGatePath'
            $resolverArgs += $allReleaseGatePath
        }
        $nextOutput = & $resolveScript @resolverArgs
        if ($nextOutput) {
            $nextActionSummary = $nextOutput | ConvertFrom-Json
        }
    } catch {
        $overallFail = $true
        if ($phaseResults.Count -gt 0) {
            $phaseResults[-1].failure_hints += "failed to generate next-action recommendation: $($_.Exception.Message)"
        }
    }
} elseif ($primaryPhase) {
    $overallFail = $overallFail -or (-not (Test-Path $allReportPath))
}

$cycle = [ordered]@{
    schema_version = 'xinxin-recovery-cycle/1.1'
    started_at = Get-Date -Format 'o'
    run_dir = $runRootPath
    run_id_prefix = $safeRunIdPrefix
    run_id = $cycleStamp
    phases = @($phaseResults | ForEach-Object { [pscustomobject]$_ })
    next_action_step = if ($nextActionSummary -and $nextActionSummary.recommended_step) { [string]$nextActionSummary.recommended_step } else { 'unknown' }
    next_action_command = if ($nextActionSummary -and $nextActionSummary.recommended_command) { [string]$nextActionSummary.recommended_command } else { '' }
    outputs = [ordered]@{
        cycle_root = $bundleRoot
        cycle_digest = $cycleDigestPath
        cycle_digest_markdown = $cycleDigestMarkdownPath
        cycle_next_action_recommendation = $nextActionPath
        baseline_bundle = if ($phaseResults[0]) { $phaseResults[0].output_bundle } else { '' }
        gate_bundle = if ($phaseResults -and $phaseResults.Count -gt 1) { $phaseResults[1].output_bundle } else { '' }
        all_bundle = if ($phaseResults.Count -ge 1 -and $phaseResults[-1].line -eq 'all') { $phaseResults[-1].output_bundle } else { '' }
    }
    summary = [ordered]@{
        pass = -not $overallFail
        requested_phase_count = $requestedPhases.Count
        executed_phase_count = $phaseResults.Count
        requested_phases = $requestedPhases
        failing_phases = @($phaseResults | Where-Object { -not $_.pass } | Select-Object -ExpandProperty line)
        stopped_on_fail = [bool]$StopOnFail
        stop_phase = if ($overallFail -and $StopOnFail -and $phaseResults.Count -lt $requestedPhases.Count) { $phaseResults[-1].line } else { '' }
    }
    finished_at = Get-Date -Format 'o'
}

$cycle | ConvertTo-Json -Depth 20 | Set-Content -Path $cycleReport -Encoding UTF8

if ($cycleMarkdown) {
    $lines = @()
    $lines += '# Xinxin Recovery Cycle Summary'
    $lines += ''
    $lines += "run_dir: $runRootPath"
    $lines += "run_id_prefix: $safeRunIdPrefix"
    $lines += "run_id: $cycleStamp"
    $lines += "pass: $($cycle.summary.pass)"
    $lines += "requested_phases: $($requestedPhases -join ', ')"
    $lines += "executed_phases: $($cycle.summary.executed_phase_count)"
    if ($cycle.summary.failing_phases.Count -gt 0) {
        $lines += "failing_phases: $($cycle.summary.failing_phases -join ', ')"
    }
    $lines += ''
    $lines += '| line | pass | gate_pass | health_status | health_score | needs_attention | report |'
    $lines += '| --- | --- | --- | --- | --- | --- | --- |'
    foreach ($phase in $cycle.phases) {
        $line = [string]$phase.line
        $pass = [string]$phase.pass
        $gate = if ($null -eq $phase.gate_pass) { '' } else { [string]$phase.gate_pass }
        $healthStatus = [string]$phase.health_status
        $score = [string]$phase.health_score
        $attention = [string]$phase.needs_attention
        $reportPath = [string]$phase.report
        $lines += "| $line | $pass | $gate | $healthStatus | $score | $attention | $reportPath |"
    }

    if ($nextActionSummary) {
        $lines += ''
        $lines += '## Next Action'
        $lines += "step: $($nextActionSummary.recommended_step)"
        $lines += "command: $($nextActionSummary.recommended_command)"
        if ($nextActionSummary.reason) {
            $lines += "reason: $($nextActionSummary.reason)"
        }
    }

    $lines += ''
    $lines += '## Deliverables'
    $lines += "- cycle report: $cycleReport"
    $lines += "- cycle digest: $cycleDigestPath"
    $lines += "- next-action recommendation: $nextActionPath"
    Set-Content -Path $cycleMarkdown -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
}

Write-Host "recovery_cycle_report=$cycleReport"
Write-Host "recovery_cycle_root=$bundleRoot"
Write-Host "next_action_recommendation=$nextActionPath"
Write-Host "cycle_digest=$cycleDigestPath"

if (-not $NoExit) {
    if (-not $cycle.summary.pass) {
        exit 1
    }
}
