param(
    [string]$ReportPath = '',
    [string]$RunDir = '.\xinxin-run',
    [string]$RunIdPrefix = '',
    [string]$CollectPath = '',
    [string]$RemediationPath = '',
    [string]$NextActionPath = '',
    [string]$OutputPath = '',
    [string]$MarkdownOutputPath = '',
    [switch]$HumanReadable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SafeToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    return ($Value -replace '[\\/:*?"<>|\s]+', '_')
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    try {
        return Get-Content -Raw $Path | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-LatestFile {
    param(
        [string]$RootDir,
        [string]$NamePattern,
        [string]$Contains = ''
    )
    if (-not (Test-Path $RootDir)) {
        return $null
    }
    $files = Get-ChildItem -Path $RootDir -Recurse -File | Where-Object { $_.Name -like $NamePattern }
    if ($files.Count -eq 0) {
        return $null
    }
    if (-not [string]::IsNullOrWhiteSpace($Contains)) {
        $filtered = $files | Where-Object { $_.Name -like "*$Contains*" -or $_.FullName -like "*$Contains*" }
        if ($filtered.Count -gt 0) {
            $files = $filtered
        }
    }
    return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function New-FallbackReport {
    param(
        [string]$RunDirPath,
        [string]$RunIdPrefix,
        [string]$CollectPath,
        [string]$RemediationPath,
        [string]$NextActionPath
    )

    $collectSummary = Read-JsonSafe -Path $CollectPath
    $remediationSummary = Read-JsonSafe -Path $RemediationPath

    $healthGateBlocked = if ($collectSummary -and $collectSummary.health_gate -and $collectSummary.health_gate.blocked) {
        [bool]$collectSummary.health_gate.blocked
    } else {
        $false
    }
    $healthStatus = if ($collectSummary -and $collectSummary.health_status) { [string]$collectSummary.health_status } else { 'unknown' }
    $healthScore = if ($collectSummary -and $null -ne $collectSummary.health_score) { [int]$collectSummary.health_score } else { 0 }
    $needsAttention = if ($collectSummary -and $null -ne $collectSummary.needs_attention) { [bool]$collectSummary.needs_attention } else { $false }
    $healthReasons = if ($collectSummary -and $collectSummary.health_reasons) { @($collectSummary.health_reasons) } else { @() }
    $collectNextAction = if ($collectSummary -and $collectSummary.next_action) { $collectSummary.next_action } else { $null }
    $remediationSteps = if ($remediationSummary -and $remediationSummary.remediation_plan) { @($remediationSummary.remediation_plan) } else { @() }

    return [ordered]@{
        schema_version = 'xinxin-recovery-digest/1.1'
        timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
        started_at = Get-Date -Format 'o'
        run_dir = $RunDirPath
        line = 'all'
        run_id = 'fallback'
        run_id_prefix = if ([string]::IsNullOrWhiteSpace($RunIdPrefix)) { $null } else { $RunIdPrefix }
        summary = [ordered]@{
            pass = -not $healthGateBlocked
            gate_required = $false
            gate_pass = if ($collectSummary -and $collectSummary.health_gate) { [bool](-not $collectSummary.health_gate.blocked) } else { $null }
            message = 'synthesized fallback summary (report file unavailable)'
        }
        outputs = [ordered]@{
            run_log = ''
            run_log_summary = ''
            release_gate = ''
            report = ''
            next_action_collect = $CollectPath
            remediation_plan = $RemediationPath
            remediation_plan_markdown = ''
            next_action = $NextActionPath
        }
        next_action = $collectNextAction
        health_status = $healthStatus
        health_score = $healthScore
        needs_attention = $needsAttention
        health_reasons = $healthReasons
        remediation_plan_steps = $remediationSteps.Count
        remediation_validation_hint = if ($remediationSummary -and $remediationSummary.validation_hint) { [string]$remediationSummary.validation_hint } else { '' }
        failure_hints = @('release-line report missing; synthesized from latest artifacts')
    }
}

function Build-RecoveryCommands {
    param(
        [string]$Step,
        [string]$Line,
        [string]$Prefix
    )
    $commands = New-Object System.Collections.Generic.List[string]
    $safePrefix = Get-SafeToken $Prefix
    $lineText = if ([string]::IsNullOrWhiteSpace($Line)) { 'all' } else { $Line }
    $prefixText = if ([string]::IsNullOrWhiteSpace($safePrefix)) { '' } else { " -RunIdPrefix $safePrefix" }

    switch ($Step) {
        'rerun_gate' {
            $commands.Add("powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line gate$prefixText -NoFail")
        }
        'rerun_all' {
            $commands.Add("powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line all$prefixText -NoFail")
        }
        'rerun_baseline' {
            $commands.Add("powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line baseline$prefixText -NoFail")
            $commands.Add("powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line all$prefixText -NoFail")
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace($safePrefix)) {
                $commands.Add("powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line $lineText -RunIdPrefix $safePrefix -NoFail")
            } else {
                $commands.Add("powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line $lineText -NoFail")
            }
        }
    }
    return @($commands)
}

function Write-MarkdownDigest {
    param(
        [psobject]$Digest,
        [string]$OutputPath
    )

    $lines = @()
    $lines += '# Xinxin Recovery Digest'
    $lines += ''
    $lines += '| Field | Value |'
    $lines += '| --- | --- |'
    $lines += "| run_dir | $($Digest.run_dir) |"
    $lines += "| line | $($Digest.line) |"
    $lines += "| run_id_prefix | $($Digest.run_id_prefix) |"
    $lines += "| status | $($Digest.status) |"
    $lines += "| summary_pass | $($Digest.summary_pass) |"
    $lines += "| gate_required | $($Digest.gate_required) |"
    $lines += "| gate_pass | $($Digest.gate_pass) |"
    $lines += "| next_action_step | $($Digest.next_action_step) |"
    $lines += "| next_action_command | $($Digest.next_action_command) |"
    $lines += "| remediation_plan_steps | $($Digest.remediation_plan_steps) |"
    $lines += "| remediation_validation_hint | $($Digest.remediation_validation_hint) |"

    $lines += ''
    $lines += '## artifacts'
    $lines += "| kind | path |"
    $lines += "| --- | --- |"
    $lines += "| report | $($Digest.artifacts.report) |"
    $lines += "| collect | $($Digest.artifacts.next_action_collect) |"
    $lines += "| remediation_plan | $($Digest.artifacts.remediation_plan) |"
    $lines += "| remediation_plan_markdown | $($Digest.artifacts.remediation_plan_markdown) |"
    $lines += "| next_action_recommendation | $($Digest.artifacts.next_action_recommendation) |"

    $lines += ''
    $lines += '## health'
    $lines += "| field | value |"
    $lines += "| --- | --- |"
    $lines += "| health_status | $($Digest.health_status) |"
    $lines += "| health_score | $($Digest.health_score) |"
    $lines += "| needs_attention | $($Digest.needs_attention) |"
    if ($Digest.health_reasons -and $Digest.health_reasons.Count -gt 0) {
        $idx = 1
        foreach ($reason in $Digest.health_reasons) {
            $lines += "| health_reason_$idx | $reason |"
            $idx++
        }
    } else {
        $lines += "| health_reasons | (none) |"
    }

    if ($Digest.next_action_playbooks -and $Digest.next_action_playbooks.Count -gt 0) {
        $lines += ''
        $lines += '## next action playbooks'
        foreach ($book in $Digest.next_action_playbooks) {
            $lines += "- $book"
        }
    }

    if ($Digest.recommended_commands -and $Digest.recommended_commands.Count -gt 0) {
        $lines += ''
        $lines += '## recommended commands'
        $i = 1
        foreach ($cmd in $Digest.recommended_commands) {
            $lines += "### Option $i"
            $lines += '```powershell'
            $lines += $cmd
            $lines += '```'
            $i++
        }
    }

    if ($Digest.recovery_commands -and $Digest.recovery_commands.Count -gt 0) {
        $lines += ''
        $lines += '## fallback recovery commands'
        foreach ($cmd in $Digest.recovery_commands) {
            $lines += "- $cmd"
        }
    }

    if ($Digest.failure_hints -and $Digest.failure_hints.Count -gt 0) {
        $lines += ''
        $lines += '## failure_hints'
        foreach ($hint in $Digest.failure_hints) {
            $lines += "- $hint"
        }
    }
    Set-Content -Path $OutputPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
}

$safeRunIdPrefix = Get-SafeToken $RunIdPrefix
$runRoot = Resolve-Path $RunDir -ErrorAction SilentlyContinue
$qaDir = if ($runRoot) {
    Join-Path $runRoot 'qa'
} else {
    $RunDir
}
$selectedReportPath = $ReportPath

if (-not $ReportPath) {
    if (Test-Path $qaDir) {
        $selectedReportPath = Get-LatestFile -RootDir $qaDir -NamePattern 'release-line-report.json' -Contains $safeRunIdPrefix
    }
    if (-not $selectedReportPath -and (Test-Path $RunDir)) {
        $selectedReportPath = Get-LatestFile -RootDir $RunDir -NamePattern 'release-line-report.json' -Contains $safeRunIdPrefix
    }
}

if ($selectedReportPath) {
    $report = Read-JsonSafe -Path $selectedReportPath
}
if (-not $report) {
    $fallbackCollectPath = if ($CollectPath) { $CollectPath } else {
        if (Test-Path $qaDir) { Get-LatestFile -RootDir $qaDir -NamePattern 'next-action-collect.json' -Contains $safeRunIdPrefix } else { $null }
    }
    $fallbackRemediationPath = if ($RemediationPath) { $RemediationPath } else {
        if (Test-Path $qaDir) { Get-LatestFile -RootDir $qaDir -NamePattern 'remediation-plan.json' -Contains $safeRunIdPrefix } else { $null }
    }
    if (-not $fallbackCollectPath) {
        throw 'release-line report not found and next-action collect output is unavailable.'
    }
    $fallbackNextActionPath = if ($NextActionPath) { $NextActionPath } else {
        if (Test-Path $qaDir) { Get-LatestFile -RootDir $qaDir -NamePattern 'next-action-recommendation.md' -Contains $safeRunIdPrefix } else { $null }
    }
    $report = New-FallbackReport -RunDirPath (if ($runRoot) { $runRoot.Path } else { $RunDir }) -RunIdPrefix $safeRunIdPrefix -CollectPath $fallbackCollectPath -RemediationPath $fallbackRemediationPath -NextActionPath $fallbackNextActionPath
    $selectedReportPath = $null
}

$bundleDir = if ($selectedReportPath) { Split-Path $selectedReportPath } else { $qaDir }
$outputs = if ($report.outputs) { $report.outputs } else { @{} }
$collectPath = if ($outputs.next_action_collect) { $outputs.next_action_collect } else { Get-LatestFile -RootDir $bundleDir -NamePattern 'next-action-collect.json' -Contains $safeRunIdPrefix }
$remediationPlanPath = if ($outputs.remediation_plan) { $outputs.remediation_plan } else { Get-LatestFile -RootDir $bundleDir -NamePattern 'remediation-plan.json' -Contains $safeRunIdPrefix }
$remediationMarkdownPath = if ($outputs.remediation_plan_markdown) { $outputs.remediation_plan_markdown } else { Get-LatestFile -RootDir $bundleDir -NamePattern 'remediation-plan.md' -Contains $safeRunIdPrefix }
$nextActionPath = if ($outputs.next_action) { $outputs.next_action } else { Get-LatestFile -RootDir $bundleDir -NamePattern 'next-action-recommendation.md' -Contains $safeRunIdPrefix }

$nextAction = $report.next_action
$collectSummary = Read-JsonSafe -Path $collectPath
$remediation = Read-JsonSafe -Path $remediationPlanPath

$nextActionStep = if ($nextAction -and $nextAction.recommended_step) { [string]$nextAction.recommended_step } else { 'unknown' }
$nextActionCommand = if ($nextAction -and $nextAction.recommended_command) { [string]$nextAction.recommended_command } else { '' }
$nextActionPriority = if ($nextAction -and $nextAction.recommended_priority) { [string]$nextAction.recommended_priority } else { '' }
$nextActionPlaybooks = if ($nextAction -and $nextAction.recommended_playbooks) { @($nextAction.recommended_playbooks) } else { @() }
$nextActionNotes = if ($nextAction -and $nextAction.recommended_notes) { @($nextAction.recommended_notes) } else { @() }
$nextActionCommands = if ($nextAction -and $nextAction.recommended_commands) { @($nextAction.recommended_commands) } else { @() }

$remediationSteps = if ($remediation -and $remediation.remediation_plan) { @($remediation.remediation_plan) } else { @() }
$remediationPlanSteps = if ($remediation -and $remediation.remediation_plan) { $remediation.remediation_plan.Count } else { 0 }
$remediationValidationHint = if ($remediation -and $remediation.validation_hint) { [string]$remediation.validation_hint } else { '' }

$healthStatus = if ($collectSummary -and $collectSummary.health_status) { [string]$collectSummary.health_status } else { if ($report.health_status) { [string]$report.health_status } else { 'unknown' } }
$healthScore = if ($collectSummary -and $null -ne $collectSummary.health_score) { [int]$collectSummary.health_score } else { if ($report.health_score) { [int]$report.health_score } else { 0 } }
$needsAttention = if ($collectSummary -and $null -ne $collectSummary.needs_attention) { [bool]$collectSummary.needs_attention } else { if ($report.needs_attention) { [bool]$report.needs_attention } else { $false } }
$healthReasons = if ($collectSummary -and $collectSummary.health_reasons) { @($collectSummary.health_reasons) } else { if ($report.health_reasons) { @($report.health_reasons) } else { @() } }

$summaryPass = if ($report.summary -and $null -ne $report.summary.pass) { [bool]$report.summary.pass } else { $false }
$gateRequired = if ($report.summary -and $null -ne $report.summary.gate_required) { [bool]$report.summary.gate_required } else { $false }
$gatePass = if ($report.summary -and $null -ne $report.summary.gate_pass) { [bool]$report.summary.gate_pass } else { $false }

$failureHints = @()
if ($nextAction -and $nextAction.schema_validation -and -not $nextAction.schema_validation.valid) {
    $failureHints += "next-action schema validation failed: $($nextAction.schema_validation.errors -join '; ')"
}
if ($collectSummary -and $collectSummary.health_gate -and $collectSummary.health_gate.blocked) {
    $failureHints += 'collect health gate blocked'
}
if ($remediation -and $remediation.health_gate_blocked) {
    $failureHints += 'remediation health_gate_blocked'
}
if ($report.failure_hints) {
    $failureHints += @($report.failure_hints)
}

$recommendedCommands = @()
if ($nextActionCommands -and $nextActionCommands.Count -gt 0) {
    $recommendedCommands += $nextActionCommands
} elseif ($nextActionCommand) {
    $recommendedCommands += $nextActionCommand
} elseif ($remediationSteps -and $remediationSteps.Count -gt 0 -and $remediationSteps[0].commands) {
    $recommendedCommands += @($remediationSteps[0].commands)
}

$recoveryCommands = Build-RecoveryCommands -Step $nextActionStep -Line $report.line -Prefix $safeRunIdPrefix
if ($nextActionCommand) {
    $recoveryCommands = @($nextActionCommand) + $recoveryCommands
}

$runIdPrefixFromReport = if ($report.run_id_prefix) { [string]$report.run_id_prefix } else { $safeRunIdPrefix }
if ([string]::IsNullOrWhiteSpace($runIdPrefixFromReport)) {
    $runIdPrefixFromReport = ''
}

$digest = [ordered]@{
    timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    run_dir = if ($runRoot) { $runRoot.Path } else { $RunDir }
    line = if ($report.line) { [string]$report.line } else { if ($report.summary -and $null -ne $report.summary.gate_required) { if ($report.summary.gate_required) { 'gate' } else { 'baseline' } } else { 'all' } }
    run_id_prefix = if ([string]::IsNullOrWhiteSpace($runIdPrefixFromReport)) { $null } else { $runIdPrefixFromReport }
    status = if ($summaryPass) { 'pass' } else { 'fail' }
    summary_pass = $summaryPass
    gate_required = $gateRequired
    gate_pass = $gatePass
    summary_message = if ($report.summary -and $report.summary.message) { [string]$report.summary.message } else { '' }
    next_action_step = $nextActionStep
    next_action_command = $nextActionCommand
    next_action_priority = $nextActionPriority
    next_action_playbooks = $nextActionPlaybooks
    next_action_notes = $nextActionNotes
    recommended_commands = $recommendedCommands
    recovery_commands = $recoveryCommands
    remediation_plan_steps = $remediationPlanSteps
    remediation_validation_hint = $remediationValidationHint
    remediation_first_plan = if ($remediationSteps.Count -gt 0) { $remediationSteps[0] } else { $null }
    health_status = $healthStatus
    health_score = $healthScore
    needs_attention = $needsAttention
    health_reasons = $healthReasons
    artifacts = [ordered]@{
        report = $ReportPath
        next_action_collect = $collectPath
        remediation_plan = $remediationPlanPath
        remediation_plan_markdown = $remediationMarkdownPath
        next_action_recommendation = $nextActionPath
    }
    failure_hints = $failureHints | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

if ($MarkdownOutputPath) {
    Write-MarkdownDigest -Digest $digest -OutputPath $MarkdownOutputPath
    if (-not $OutputPath) {
        $OutputPath = [System.IO.Path]::ChangeExtension($MarkdownOutputPath, '.json')
    }
}

if ($OutputPath) {
    $digest | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8
}

if ($HumanReadable) {
    Write-Host 'xinxin recovery digest'
    Write-Host "status=$($digest.status) line=$($digest.line) pass=$($digest.summary_pass)"
    Write-Host "next_action_step=$($digest.next_action_step)"
    Write-Host "next_action_command=$($digest.next_action_command)"
    if ($digest.remediation_plan_steps -gt 0) {
        Write-Host "remediation_plan_steps=$($digest.remediation_plan_steps)"
    }
    if ($digest.remediation_validation_hint) {
        Write-Host "remediation_validation_hint=$($digest.remediation_validation_hint)"
    }
    Write-Host "health=$($digest.health_status) score=$($digest.health_score) needs_attention=$($digest.needs_attention)"
    Write-Host "report=$($digest.artifacts.report)"
    if ($digest.artifacts.next_action_collect) {
        Write-Host "next_action_collect=$($digest.artifacts.next_action_collect)"
    }
    if ($digest.artifacts.remediation_plan) {
        Write-Host "remediation_plan=$($digest.artifacts.remediation_plan)"
    }
    Write-Host 'recommended commands:'
    if ($digest.recommended_commands.Count -gt 0) {
        $idx = 1
        foreach ($cmd in $digest.recommended_commands) {
            Write-Host ("  $idx) $cmd")
            $idx++
        }
    } else {
        Write-Host '  (none)'
    }
    Write-Host 'fallback commands:'
    if ($digest.recovery_commands.Count -gt 0) {
        $idx = 1
        foreach ($cmd in $digest.recovery_commands) {
            Write-Host ("  $idx) $cmd")
            $idx++
        }
    } else {
        Write-Host '  (none)'
    }
    if ($digest.failure_hints.Count -gt 0) {
        Write-Host 'failure_hints:'
        foreach ($hint in $digest.failure_hints) {
            Write-Host ("  - $hint")
        }
    }
}

if (-not $HumanReadable) {
    $digest | ConvertTo-Json -Depth 20
}
