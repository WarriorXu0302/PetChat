param(
    [string]$OutputRoot = '.\xinxin-run\qa\recovery-cycles',
    [string]$CycleName = '',
    [string]$CycleReportPath = '',
    [string]$OutputJson = '',
    [string]$OutputMarkdown = '',
    [switch]$HumanReadable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$resolvedOutputRoot = if ([System.IO.Path]::IsPathRooted($OutputRoot)) {
    $OutputRoot
} else {
    Join-Path $repoRoot $OutputRoot
}
$outputRootPath = if (Test-Path $resolvedOutputRoot) {
    (Resolve-Path $resolvedOutputRoot).Path
} else {
    throw "OutputRoot not found: $OutputRoot"
}

function Find-LatestCycleReport {
    param([string]$RootPath)

    $reports = Get-ChildItem -Path $RootPath -Recurse -Filter 'recovery-cycle-report.json' -File -ErrorAction SilentlyContinue
    if (-not $reports) {
        return $null
    }
    return ($reports | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

if (-not [string]::IsNullOrWhiteSpace($CycleReportPath)) {
    $resolvedCycleReportPath = if ([System.IO.Path]::IsPathRooted($CycleReportPath)) {
        $CycleReportPath
    } else {
        Join-Path $repoRoot $CycleReportPath
    }
    if (-not (Test-Path $resolvedCycleReportPath)) {
        throw "Cycle report not found: $CycleReportPath"
    }
    $selectedReportPath = $resolvedCycleReportPath
} elseif (-not [string]::IsNullOrWhiteSpace($CycleName)) {
    $cycleDir = Join-Path $outputRootPath $CycleName
    if (-not (Test-Path $cycleDir)) {
        throw "Cycle directory not found: $cycleDir"
    }
    $selectedReportPath = Join-Path $cycleDir 'recovery-cycle-report.json'
    if (-not (Test-Path $selectedReportPath)) {
        $selectedReportPath = Find-LatestCycleReport -RootPath $cycleDir
        if (-not $selectedReportPath) {
            throw "No recovery-cycle-report.json in cycle directory: $cycleDir"
        }
    }
} else {
    $selectedReportPath = Find-LatestCycleReport -RootPath $outputRootPath
    if (-not $selectedReportPath) {
        throw "No recovery-cycle-report.json found under: $outputRootPath"
    }
}

$cycleDirPath = Split-Path -Parent $selectedReportPath
$defaultOutputJson = Join-Path $cycleDirPath 'release-cycle-board.json'
$defaultOutputMarkdown = Join-Path $cycleDirPath 'release-cycle-board.md'
$boardJson = if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $defaultOutputJson
} else {
    if ([System.IO.Path]::IsPathRooted($OutputJson)) { $OutputJson } else { Join-Path $repoRoot $OutputJson }
}
$boardMarkdown = if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) {
    $defaultOutputMarkdown
} else {
    if ([System.IO.Path]::IsPathRooted($OutputMarkdown)) { $OutputMarkdown } else { Join-Path $repoRoot $OutputMarkdown }
}

$cycle = Get-Content -Raw -Path $selectedReportPath | ConvertFrom-Json

$board = [ordered]@{
    schema_version = 'xinxin-recovery-board/1.0'
    generated_at = Get-Date -Format 'o'
    source_cycle = $selectedReportPath
    run_dir = $cycle.run_dir
    run_id = $cycle.run_id
    run_id_prefix = $cycle.run_id_prefix
    summary = [ordered]@{
        pass = $cycle.summary.pass
        requested_phase_count = $cycle.summary.requested_phase_count
        executed_phase_count = $cycle.summary.executed_phase_count
        failing_phases = if ($cycle.summary.failing_phases) { @($cycle.summary.failing_phases) } else { @() }
        requested_phases = if ($cycle.summary.requested_phases) { @($cycle.summary.requested_phases) } else { @() }
        stop_phase = if ($cycle.summary.stop_phase) { [string]$cycle.summary.stop_phase } else { '' }
    }
    command_center = [ordered]@{
        recommended_step = if ($cycle.next_action_step) { [string]$cycle.next_action_step } else { 'unknown' }
        recommended_command = if ($cycle.next_action_command) { [string]$cycle.next_action_command } else { '' }
        next_action_file = if ($cycle.outputs -and $cycle.outputs.cycle_next_action_recommendation) { [string]$cycle.outputs.cycle_next_action_recommendation } else { Join-Path $cycle.outputs.cycle_root 'next-action-recommendation.md' }
    }
    health = [ordered]@{
        latest_phase = $null
        latest_health_status = 'unknown'
        latest_health_score = 0
        latest_needs_attention = $false
    }
    phases = @()
    deliverables = [ordered]@{
        cycle_report = $selectedReportPath
        cycle_digest = if ($cycle.outputs -and $cycle.outputs.cycle_digest) { [string]$cycle.outputs.cycle_digest } else { '' }
        cycle_digest_markdown = if ($cycle.outputs -and $cycle.outputs.cycle_digest_markdown) { [string]$cycle.outputs.cycle_digest_markdown } else { '' }
        cycle_bundle = if ($cycle.outputs -and $cycle.outputs.cycle_root) { [string]$cycle.outputs.cycle_root } else { $cycleDirPath }
    }
    blockers = @()
    recommendations = @()
}

if ($cycle.phases) {
    $latestPhase = $cycle.phases | Select-Object -Last 1
    $board.health.latest_phase = [string]$latestPhase.line
    $board.health.latest_health_status = if ($latestPhase.health_status) { [string]$latestPhase.health_status } else { 'unknown' }
    $board.health.latest_health_score = if ($null -ne $latestPhase.health_score) { [int]$latestPhase.health_score } else { 0 }
    $board.health.latest_needs_attention = if ($null -ne $latestPhase.needs_attention) { [bool]$latestPhase.needs_attention } else { $false }
}

if ($cycle.phases) {
    foreach ($phase in $cycle.phases) {
        $board.phases += [ordered]@{
            line = [string]$phase.line
            pass = [bool]$phase.pass
            gate_pass = if ($null -eq $phase.gate_pass) { $null } else { [bool]$phase.gate_pass }
            health_status = if ($phase.health_status) { [string]$phase.health_status } else { 'unknown' }
            health_score = if ($null -ne $phase.health_score) { [int]$phase.health_score } else { 0 }
            needs_attention = if ($null -ne $phase.needs_attention) { [bool]$phase.needs_attention } else { $false }
            output_bundle = [string]$phase.output_bundle
            report = [string]$phase.report
            failure_hints = if ($phase.failure_hints) { @($phase.failure_hints) } else { @() }
        }
        if (-not $phase.pass) {
            $board.blockers += "$($phase.line): $($phase.summary_message)"
            if ($phase.failure_hints) {
                foreach ($hint in $phase.failure_hints) {
                    if (-not [string]::IsNullOrWhiteSpace($hint)) {
                        $board.blockers += "$($phase.line): $hint"
                    }
                }
            }
        }
    }
}

$commandByStep = @{
    baseline = "powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line baseline -RunDir $($board.run_dir) -RunIdPrefix $($board.run_id_prefix)"
    gate = "powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line gate -RunIdPrefix $($board.run_id_prefix) -RunDir $($board.run_dir) -NoFail"
    all = "powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line all -RunIdPrefix $($board.run_id_prefix) -RunDir $($board.run_dir) -NoFail"
    'release-cycle' = "powershell -ExecutionPolicy Bypass -File .\scripts\execute-xinxin-recovery-cycle.ps1 -RunIdPrefix $($board.run_id_prefix) -RunDir $($board.run_dir)"
}

if ($board.command_center.recommended_command) {
    $board.recommendations += $board.command_center.recommended_command
}
if ($board.command_center.recommended_step -and $commandByStep.ContainsKey($board.command_center.recommended_step)) {
    $board.recommendations += $commandByStep[$board.command_center.recommended_step]
}
if (-not $board.recommendations -or $board.recommendations.Count -eq 0) {
    if ($board.summary.failing_phases -and $board.summary.failing_phases.Count -gt 0) {
        if ($board.summary.failing_phases -contains 'baseline') {
            $board.recommendations += $commandByStep['baseline']
            $board.recommendations += $commandByStep['release-cycle']
        } else {
            $board.recommendations += $commandByStep['gate']
            $board.recommendations += $commandByStep['all']
        }
    } else {
        $board.recommendations += $commandByStep['release-cycle']
    }
}

$board | ConvertTo-Json -Depth 20 | Set-Content -Path $boardJson -Encoding UTF8

if ($boardMarkdown) {
    $lines = @()
    $lines += '# Xinxin Recovery Board'
    $lines += ''
    $lines += "run_dir: $($board.run_dir)"
    $lines += "run_id_prefix: $($board.run_id_prefix)"
    $lines += "run_id: $($board.run_id)"
    $lines += "pass: $($board.summary.pass)"
    $lines += ''
    $lines += "| line | pass | gate_pass | health_status | health_score | needs_attention |"
    $lines += "| --- | --- | --- | --- | --- | --- |"
    foreach ($phase in $board.phases) {
        $gatePass = if ($null -eq $phase.gate_pass) { '' } else { $phase.gate_pass }
        $lines += "| $($phase.line) | $($phase.pass) | $gatePass | $($phase.health_status) | $($phase.health_score) | $($phase.needs_attention) |"
    }

    if ($board.blockers -and $board.blockers.Count -gt 0) {
        $lines += ''
        $lines += '## Blockers'
        foreach ($hint in $board.blockers | Select-Object -Unique) {
            $lines += "- $hint"
        }
    }

    $lines += ''
    $lines += '## Recommended Actions'
    foreach ($cmd in $board.recommendations | Select-Object -Unique) {
        $lines += "- $cmd"
    }

    if ($board.deliverables.cycle_digest) {
        $lines += ''
        $lines += "digest: $($board.deliverables.cycle_digest)"
        if ($board.deliverables.cycle_digest_markdown) {
            $lines += "digest_md: $($board.deliverables.cycle_digest_markdown)"
        }
    }

    Set-Content -Path $boardMarkdown -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
}

Write-Host "recovery_board_json=$boardJson"
Write-Host "recovery_board_markdown=$boardMarkdown"
Write-Host "source_cycle_report=$selectedReportPath"

if ($HumanReadable) {
    Write-Host "pass=$($board.summary.pass) phases=$($board.summary.executed_phase_count)/$($board.summary.requested_phase_count)"
    Write-Host "next_action_step=$($board.command_center.recommended_step)"
    if ($board.command_center.recommended_command) {
        Write-Host "next_action_command=$($board.command_center.recommended_command)"
    }
    if ($board.summary.failing_phases -and $board.summary.failing_phases.Count -gt 0) {
        Write-Host "failing_phases=$($board.summary.failing_phases -join ',')"
    }
}
