param(
    [string]$ReportPath = $null,
    [string]$ReleaseGatePath = $null,
    [string]$RunStatusPath = $null,
    [string]$RunLogPath = $null,
    [string]$RunIdPrefix = $null,
    [string]$FallbackLine = 'all',
    [switch]$HumanReadable,
    [string]$MarkdownOutputPath = $null
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

function New-SchemaValidationState {
    return [ordered]@{
        schema_version = 'xinxin-next-action/1.1'
        source = 'unknown'
        valid = $true
        errors = [System.Collections.Generic.List[string]]::new()
        warnings = [System.Collections.Generic.List[string]]::new()
        checks = [System.Collections.Generic.List[string]]::new()
    }
}

function Add-SchemaCheck {
    param(
        [psobject]$State,
        [string]$Name,
        [bool]$IsPass,
        [string]$Message
    )

    $state.checks.Add($Name)
    if (-not $IsPass) {
        $state.warnings.Add($Message)
    }
}

function Set-SchemaFailure {
    param(
        [psobject]$State,
        [string]$Message
    )
    $state.valid = $false
    $state.errors.Add($Message)
}

function Get-RemediationPack {
    param(
        [string]$Step,
        [string]$Prefix,
        [string[]]$Hints
    )

    $commands = @()
    $playbooks = @()
    $notes = @()

    $prefixText = if ([string]::IsNullOrWhiteSpace($Prefix)) {
        ''
    } else {
        " -RunIdPrefix $Prefix"
    }

    switch ($Step) {
        'rerun_gate' {
            $commands += "powershell -ExecutionPolicy Bypass -File .\\scripts\\run-xinxin-v2.1-release-line.ps1 -Line gate$prefixText -NoFail"
            $playbooks += '.\\xinxin-run\\qa\\v2.1-qa-checklist.md'
            $playbooks += '.\\xinxin-run\\qa\\v2.1-failure-remediation-playbook.md'
            $notes += 'Start with QA checklist and verify manual review items first.'
        }
        'rerun_baseline' {
            $commands += "powershell -ExecutionPolicy Bypass -File .\\scripts\\run-xinxin-v2.1-release-line.ps1 -Line baseline$prefixText -NoFail"
            $commands += "powershell -ExecutionPolicy Bypass -File .\\scripts\\run-xinxin-v2.1-release-line.ps1 -Line all$prefixText -NoFail"
            $playbooks += '.\\xinxin-run\\qa\\v2.1-fast-track-playbook.md'
            $playbooks += '.\\xinxin-run\\qa\\v2.1-qa-checklist.md'
            $notes += 'Run baseline recovery first, then rerun full line if baseline still fails.'
        }
        'rerun_all' {
            $commands += "powershell -ExecutionPolicy Bypass -File .\\scripts\\run-xinxin-v2.1-release-line.ps1 -Line all$prefixText -NoFail"
            $playbooks += '.\\xinxin-run\\qa\\v2.1-fast-track-playbook.md'
            $notes += 'Run full-line recovery and verify both baseline and gate coverage.'
        }
        'passed' {
            $notes += 'Pipeline already passed, no rerun needed.'
        }
        default {
            $commands += "powershell -ExecutionPolicy Bypass -File .\\scripts\\run-xinxin-v2.1-release-line.ps1 -Line all$prefixText -NoFail"
            $playbooks += '.\\xinxin-run\\qa\\v2.1-fast-track-playbook.md'
            $notes += 'Fallback recovery: run quick-track checklist then rerun full line.'
        }
    }

    if ($Hints -and $Hints.Count -gt 0) {
        foreach ($hint in $Hints) {
            if ([string]::IsNullOrWhiteSpace($hint)) {
                continue
            }
            if ($hint -match 'manual review') {
                $playbooks += '.\\xinxin-run\\qa\\v2.1-qa-checklist.md'
            }
            if ($hint -match 'run-log') {
                $commands += "powershell -ExecutionPolicy Bypass -File .\\scripts\\run-xinxin-v2.1.ps1 -Mode all -RunDir .\\xinxin-run -ReviewRunLog"
            }
        }
    }

    return [ordered]@{
        commands = ($commands | Select-Object -Unique)
        playbooks = ($playbooks | Select-Object -Unique)
        notes = ($notes | Select-Object -Unique)
        recommended = if ($commands.Count -gt 0) { $commands[0] } else { '' }
    }
}

function New-Action {
    param(
        [string]$Step,
        [string]$Reason,
        [string]$Line = 'all',
        [string]$Priority = 'normal',
        [bool]$NeedNoFail = $true
    )

    $prefix = Get-SafeToken $script:resolvedRunIdPrefix
    $command = "powershell -ExecutionPolicy Bypass -File .\\scripts\\run-xinxin-v2.1-release-line.ps1 -Line $Line"
    if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        $command += " -RunIdPrefix $prefix"
    }
    if ($NeedNoFail) {
        $command += ' -NoFail'
    }

    return [ordered]@{
        step = $Step
        line = $Line
        reason = $Reason
        priority = $Priority
        command = $command
    }
}

function Write-HumanSummary {
    param([psobject]$Result)

    Write-Host 'xinxin next action summary'
    Write-Host '-----------------------'
    Write-Host ("run_id_prefix      : {0}" -f ($Result.run_id_prefix))
    Write-Host ("reason             : {0}" -f $Result.reason)
    Write-Host ("summary            : {0}" -f $Result.summary)
    Write-Host ("recommended_step    : {0}" -f $Result.recommended_step)
    Write-Host ("recommended_line    : {0}" -f $Result.recommended_line)
    Write-Host ("recommended_priority: {0}" -f $Result.recommended_priority)
    Write-Host ('recommended_command : {0}' -f ([string]::IsNullOrWhiteSpace($Result.recommended_command) ? '(none)' : $Result.recommended_command))

    if ($Result.recommended_playbooks -and $Result.recommended_playbooks.Count -gt 0) {
        Write-Host 'recommended_playbooks:'
        foreach ($playbook in $Result.recommended_playbooks) {
            Write-Host ("  - {0}" -f $playbook)
        }
    } else {
        Write-Host 'recommended_playbooks: (none)'
    }

    if ($Result.recommended_commands -and $Result.recommended_commands.Count -gt 0) {
        Write-Host 'recommended_commands (copy one):'
        $index = 1
        foreach ($cmd in $Result.recommended_commands) {
            Write-Host ("  {0}) {1}" -f $index, $cmd)
            $index++
        }
    } else {
        Write-Host 'recommended_commands (copy one): (none)'
    }

    if ($Result.recommended_notes -and $Result.recommended_notes.Count -gt 0) {
        Write-Host 'recommended_notes:'
        foreach ($note in $Result.recommended_notes) {
            Write-Host ("  - {0}" -f $note)
        }
    }

    if ($Result.schema_validation) {
        Write-Host ("schema_validation.source  : {0}" -f $Result.schema_validation.source)
        Write-Host ("schema_validation.valid   : {0}" -f $Result.schema_validation.valid)
        Write-Host ('schema_validation.errors  : {0}' -f (($Result.schema_validation.errors | ForEach-Object { $_ }) -join '; '))
        Write-Host ('schema_validation.warnings: {0}' -f (($Result.schema_validation.warnings | ForEach-Object { $_ }) -join '; '))
    }
}

function Write-MarkdownSummary {
    param(
        [psobject]$Result,
        [string]$OutputPath
    )

    $lines = @()
    $lines += '# Xinxin Next Action'
    $lines += ''
    $lines += '| Field | Value |'
    $lines += '| --- | --- |'
    $lines += "| run_id_prefix | $($Result.run_id_prefix) |"
    $lines += "| summary | $($Result.summary) |"
    $lines += "| reason | $($Result.reason) |"
    $lines += "| recommended_step | $($Result.recommended_step) |"
    $lines += "| recommended_line | $($Result.recommended_line) |"
    $lines += "| recommended_priority | $($Result.recommended_priority) |"
    $lines += "| recommended_command | $([string]::IsNullOrWhiteSpace($Result.recommended_command) ? '(none)' : $Result.recommended_command) |"
    $lines += ''

    $lines += '## recommended_playbooks'
    if ($Result.recommended_playbooks -and $Result.recommended_playbooks.Count -gt 0) {
        foreach ($book in $Result.recommended_playbooks) {
            $lines += "- $book"
        }
    } else {
        $lines += '- (none)'
    }

    $lines += ''
    $lines += '## recommended_commands'
    if ($Result.recommended_commands -and $Result.recommended_commands.Count -gt 0) {
        $index = 1
        foreach ($cmd in $Result.recommended_commands) {
            $lines += ''
            $lines += "### Option $index"
            $lines += '```powershell'
            $lines += $cmd
            $lines += '```'
            $index++
        }
    } else {
        $lines += '- (none)'
    }

    $lines += ''
    $lines += '## recommended_notes'
    if ($Result.recommended_notes -and $Result.recommended_notes.Count -gt 0) {
        foreach ($note in $Result.recommended_notes) {
            $lines += "- $note"
        }
    } else {
        $lines += '- (none)'
    }

    $lines += ''
    $lines += '## schema_validation'
    if ($Result.schema_validation) {
        $lines += "| source | $($Result.schema_validation.source) |"
        $lines += "| valid | $($Result.schema_validation.valid) |"
        $lines += "| checks | $($Result.schema_validation.checks.Count) |"
        $lines += "| warnings | $($Result.schema_validation.warnings.Count) |"
        $lines += "| errors | $($Result.schema_validation.errors.Count) |"
    } else {
        $lines += '- schema_validation unavailable'
    }

    $lines += ''
    $lines += '> Output generated by resolve-xinxin-next-action.ps1'

    Set-Content -Path $OutputPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
}

$resolvedRunIdPrefix = Get-SafeToken $RunIdPrefix
$schema = New-SchemaValidationState
$action = New-Action -Step 'rerun_all' -Reason 'default recovery' -Line $FallbackLine
$failureHints = @()
$reason = 'no actionable hints in inputs; rerun all for fresh baseline'
$sources = @{}
$sources.report = $false
$sources.release_gate = $false
$sources.run_status = $false

if ($ReportPath -and (Test-Path $ReportPath)) {
    $sources.report = $true
    $schema.source = 'report'
    try {
        $report = Get-Content -Raw $ReportPath | ConvertFrom-Json
        Add-SchemaCheck -State $schema -Name 'report_json_parse' -IsPass $true -Message 'report parsed'

        $hasSummary = $report.PSObject.Properties.Name -contains 'summary'
        Add-SchemaCheck -State $schema -Name 'report_summary_present' -IsPass $hasSummary -Message 'report.summary missing'

        if ($hasSummary -and $null -ne $report.summary) {
            $hasPass = $report.summary.PSObject.Properties.Name -contains 'pass'
            $hasGateRequired = $report.summary.PSObject.Properties.Name -contains 'gate_required'
            $hasGatePass = $report.summary.PSObject.Properties.Name -contains 'gate_pass'
            Add-SchemaCheck -State $schema -Name 'report_summary_pass_field' -IsPass $hasPass -Message 'report.summary.pass missing'
            Add-SchemaCheck -State $schema -Name 'report_summary_gate_required_field' -IsPass $hasGateRequired -Message 'report.summary.gate_required missing'
            Add-SchemaCheck -State $schema -Name 'report_summary_gate_pass_field' -IsPass $hasGatePass -Message 'report.summary.gate_pass missing'
        }

        if ($report.run_id_prefix -and -not $RunIdPrefix) {
            $resolvedRunIdPrefix = Get-SafeToken $report.run_id_prefix
        }

        if ($null -ne $report.summary -and $report.summary.pass -eq $true) {
            $action = [ordered]@{
                step = 'passed'
                line = 'none'
                reason = 'release-line report indicates pass'
                priority = 'low'
                command = ''
            }
            $reason = 'pipeline pass'
        } elseif ($null -ne $report.summary -and $report.summary.gate_required -eq $true -and $report.summary.gate_pass -eq $false) {
            $action = New-Action -Step 'rerun_gate' -Priority 'high' -Line 'gate' -Reason 'run summary requires gate pass'
            $reason = 'release-line gate required but failed'
        } elseif ($null -ne $report.summary -and $report.summary.gate_required -eq $true -and $null -eq $report.summary.gate_pass) {
            $action = New-Action -Step 'rerun_gate' -Priority 'high' -Line 'gate' -Reason 'release-line gate status unresolved'
            $reason = 'release-line gate status not final'
        } elseif ($null -ne $report.summary -and $report.summary.pass -eq $false) {
            $action = New-Action -Step 'rerun_baseline' -Priority 'high' -Line 'baseline' -Reason 'release-line failed before gate or during baseline'
            $reason = 'release-line baseline failed'
        } else {
            $action = New-Action -Step 'rerun_all' -Priority 'high' -Line $FallbackLine -Reason 'release-line report exists but lacks explicit summary'
            $reason = 'release-line report incomplete'
        }
        if ($report.PSObject.Properties.Name -contains 'failure_hints' -and $report.failure_hints) {
            $failureHints = @($report.failure_hints)
        }
    } catch {
        $action = New-Action -Step 'rerun_report_parse' -Priority 'high' -Line $FallbackLine -Reason "cannot parse report: $($_.Exception.Message)"
        $reason = 'release-line report parse failed'
        Set-SchemaFailure -State $schema -Message "report parse failed: $($_.Exception.Message)"
    }
}

if (-not $sources.report) {
    if ($ReleaseGatePath -and (Test-Path $ReleaseGatePath)) {
        $sources.release_gate = $true
        $schema.source = if ($schema.source -eq 'unknown') { 'release_gate' } else { "$($schema.source)+release_gate" }
        try {
            $gate = Get-Content -Raw $ReleaseGatePath | ConvertFrom-Json
            Add-SchemaCheck -State $schema -Name 'release_gate_json_parse' -IsPass $true -Message 'release-gate parsed'
            Add-SchemaCheck -State $schema -Name 'release_gate_decision_field' -IsPass (($gate.PSObject.Properties.Name -contains 'decision')) -Message 'release-gate decision missing'
            if ($null -ne $gate.decision -and $gate.decision -ne 'PASS') {
                $action = New-Action -Step 'rerun_gate' -Priority 'high' -Line 'gate' -Reason 'release-gate blocked'
                $reason = 'release-gate decision is blocked'
            } elseif ($null -ne $gate.decision -and $gate.decision -eq 'PASS') {
                $action = [ordered]@{
                    step = 'passed'
                    line = 'none'
                    reason = 'release-gate passed'
                    priority = 'low'
                    command = ''
                }
                $reason = 'release-gate passed'
            }
        } catch {
            $action = New-Action -Step 'rerun_release_gate_parse' -Priority 'high' -Line 'gate' -Reason "cannot parse release_gate: $($_.Exception.Message)"
            $reason = 'release-gate parse failed'
            Set-SchemaFailure -State $schema -Message "release-gate parse failed: $($_.Exception.Message)"
        }
    }

    if (($RunStatusPath) -and (Test-Path $RunStatusPath)) {
        $sources.run_status = $true
        $schema.source = if ($schema.source -eq 'unknown') { 'run_status' } else { "$($schema.source)+run_status" }
        try {
            $status = Get-Content -Raw $RunStatusPath | ConvertFrom-Json
            Add-SchemaCheck -State $schema -Name 'run_status_json_parse' -IsPass $true -Message 'run-status parsed'
            $isBlocked = $false
            if ($status.PSObject.Properties.Name -contains 'gate' -and $status.gate.PSObject.Properties.Name -contains 'ready_for_generation') {
                if ($status.gate.ready_for_generation -ne $true) {
                    $isBlocked = $true
                }
            }
            if ($isBlocked) {
                $action = New-Action -Step 'rerun_baseline' -Priority 'high' -Line 'baseline' -Reason 'pipeline gate not ready for generation'
                $reason = 'pipeline gate blocked by run-status'
            }
            if ($status.state -eq 'blocked') {
                $action = New-Action -Step 'rerun_baseline' -Priority 'high' -Line 'baseline' -Reason 'pipeline state is blocked'
                $reason = 'pipeline state blocked'
            }
        } catch {
            $action = New-Action -Step 'rerun_status_parse' -Priority 'medium' -Line $FallbackLine -Reason "cannot parse run status: $($_.Exception.Message)"
            if ($reason -eq 'pipeline pass') {
                $reason = 'run-status parse failed'
            }
            Set-SchemaFailure -State $schema -Message "run-status parse failed: $($_.Exception.Message)"
        }
    }
}

if ($RunLogPath -and -not (Test-Path $RunLogPath)) {
    $reason = 'run-log missing'
    Add-SchemaCheck -State $schema -Name 'run_log_exists' -IsPass $false -Message "run-log missing: $RunLogPath"
} else {
    Add-SchemaCheck -State $schema -Name 'run_log_exists' -IsPass $true -Message 'run-log present'
}

$remediation = Get-RemediationPack -Step $action.step -Prefix $resolvedRunIdPrefix -Hints $failureHints

$result = [ordered]@{
    run_id_prefix = if ([string]::IsNullOrWhiteSpace($resolvedRunIdPrefix)) { $null } else { $resolvedRunIdPrefix }
    sources = [ordered]@{
        report = $sources.report
        release_gate = $sources.release_gate
        run_status = $sources.run_status
    }
    reason = $reason
    recommended_step = $action.step
    recommended_line = $action.line
    recommended_command = $action.command
    recommended_priority = $action.priority
    recommended_commands = $remediation.commands
    recommended_playbooks = $remediation.playbooks
    recommended_notes = $remediation.notes
    summary = if ($action.step -eq 'passed') {
        'pass'
    } else {
        'need_recovery'
    }
    schema_validation = $schema
}

if ($RunIdPrefix) {
    $result.input_run_id_prefix = Get-SafeToken $RunIdPrefix
}

if ($MarkdownOutputPath) {
    Write-MarkdownSummary -Result $result -OutputPath $MarkdownOutputPath
}

if ($HumanReadable) {
    Write-HumanSummary -Result $result
    return
}

$result | ConvertTo-Json -Depth 10
