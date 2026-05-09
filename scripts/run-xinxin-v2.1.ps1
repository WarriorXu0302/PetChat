param(
    [ValidateSet('check','pack','full','audit','all','log','gate')],
    [string]$Mode = 'all',
    [string]$RunDir = '.\xinxin-run',
    [switch]$NoStatusWrite,
    [switch]$RequireReleaseGate,
    [switch]$ReviewRunLog,
    [string]$ReleaseGateOutputFile = $null,
    [string]$RunLogOutputFile = $null,
    [string]$RunLogSummaryFile = $null
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$runPetWorkflow = Join-Path $scriptDir 'run-pet-workflow.ps1'
$collectScript = Join-Path $scriptDir 'collect-pet-run-status.ps1'
$buildScript = Join-Path $scriptDir 'build-xinxin-delivery-manifest.ps1'
$auditScript = Join-Path $scriptDir 'audit-xinxin-v2.1.ps1'
$runLogScript = Join-Path $scriptDir 'generate-v2.1-run-log.ps1'
$releaseGateScript = Join-Path $scriptDir 'check-v2.1-release-gate.ps1'

if (-not (Test-Path $runPetWorkflow)) {
    throw "Required script missing: $runPetWorkflow"
}
if (-not (Test-Path $collectScript)) {
    throw "Required script missing: $collectScript"
}
if (-not (Test-Path $buildScript)) {
    throw "Required script missing: $buildScript"
}
if (-not (Test-Path $auditScript)) {
    throw "Required script missing: $auditScript"
}
if (-not (Test-Path $runLogScript)) {
    throw "Required script missing: $runLogScript"
}
if (-not (Test-Path $releaseGateScript)) {
    throw "Required script missing: $releaseGateScript"
}

$runRoot = Resolve-Path $RunDir

function Write-Section([string]$title) {
    Write-Host "`n=== $title ==="
}

function Write-StatusLine([bool]$pass, [string]$label, [string]$detail) {
    $tag = if ($pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}: {2}" -f $tag, $label, $detail)
}

function Invoke-RunLog([psobject]$AuditData = $null) {
    $runLogParams = @{
        RunDir  = $runRoot
        NoWrite = $NoStatusWrite
    }
    if ($null -ne $AuditData) {
        $runLogParams.AuditData = $AuditData
    }
    if ($RunLogOutputFile) {
        $runLogParams.OutputFile = $RunLogOutputFile
    }
    if ($RunLogSummaryFile) {
        $runLogParams.SummaryFile = $RunLogSummaryFile
    }
    return & $runLogScript @runLogParams
}

switch ($Mode) {
    'check' {
        Write-Section 'Check pipeline health'
        $status = & $collectScript -RunDir $runRoot -NoWrite:$NoStatusWrite
        $status | ConvertTo-Json -Depth 3
    }
    'pack' {
        Write-Section 'Generate delivery manifest'
        $pack = & $buildScript -RunDir $runRoot -RequireHealthy -NoWrite:$false
        $pack | ConvertTo-Json -Depth 3
    }
    'audit' {
        Write-Section 'Audit run with PASS/FAIL matrix'
        $audit = & $auditScript -RunDir $runRoot -NoWrite:$NoStatusWrite
        Write-Host ("Overall=$($audit.summary.overall), gate_ready=$($audit.status.gate.ready_for_generation)")
        Write-Host '--- check items ---'
        foreach ($item in $audit.checks) {
            $isPass = $item.status -eq 'PASS'
            Write-StatusLine -pass:$isPass -label $item.name -detail $item.message
        }
        Write-Host '--- frame matrix ---'
        foreach ($item in $audit.state_matrix) {
            $ok = $item.status -eq 'PASS'
            Write-StatusLine -pass:$ok -label $item.state -detail ('{0}/{1} frames' -f $item.actual_frames, $item.expected_frames)
        }
        Write-Host "Manual visual review: $($audit.manual_review.status)"
        Write-Host "Audit report: $($audit.output_file)"
        Write-Host 'Next QA:'
        Write-Host '- qa/v2.1-qa-checklist.md'
        Write-Host '- qa/v2.1-failure-remediation-playbook.md'
        Write-Host '- qa/v2.1-fast-track-playbook.md'
        Write-Host '- qa/run-log-template.md'
    }
    'log' {
        Write-Section 'Create run log from latest audit'
        $log = Invoke-RunLog
        Write-Host ('Run log generated: ' + $log.output_file)
        Write-Host 'Suggested next step: review and sync human-visual status manually.'
    }
    'all' {
        Write-Section 'All-in-one xinxin v2.1 pipeline'
        & $runPetWorkflow -RunDir $runRoot -RequireHealthy
        $pack = & $buildScript -RunDir $runRoot -RequireHealthy
        Write-Host ('artifacts_count=' + $pack.artifacts.Count)
        $audit = & $auditScript -RunDir $runRoot
        Write-Host ('audit_report=' + $audit.output_file)

        if (-not $ReviewRunLog) {
            $log = Invoke-RunLog -AuditData $audit
            Write-Host ('run_log=' + $log.output_file)
            Write-Host ('run_log_summary=' + $log.summary_file)
        }

        $runReleaseGate = $RequireReleaseGate -or $ReviewRunLog
        if ($runReleaseGate) {
            Write-Section 'Run release gate'
            $gateParams = @{
                RunDir = $runRoot
                NoWrite = $NoStatusWrite
            }
            if ($RequireReleaseGate) {
                $gateParams.RequirePass = $true
            }
            if ($ReleaseGateOutputFile) {
                $gateParams.OutputFile = $ReleaseGateOutputFile
            }
            $gate = & $releaseGateScript @gateParams
            Write-Host ('release_gate=' + $gate.decision)
            if ($gate.output_file) {
                Write-Host ('release_gate_file=' + $gate.output_file)
            } elseif ($ReleaseGateOutputFile) {
                Write-Host ('release_gate_file=' + $ReleaseGateOutputFile)
            }
            if ($ReviewRunLog) {
                $log = Invoke-RunLog -AuditData $audit
                Write-Host ('run_log=' + $log.output_file)
                Write-Host ('run_log_summary=' + $log.summary_file)
            }
        } else {
            Write-Host 'Manual review still required for final PASS decision.'
        }
    }
    'gate' {
        Write-Section 'Release gate check for xinxin v2.1'
        $gateParams = @{
            RunDir = $runRoot
            NoWrite = $NoStatusWrite
        }
        if ($ReleaseGateOutputFile) {
            $gateParams.OutputFile = $ReleaseGateOutputFile
        }
        $gate = & $releaseGateScript @gateParams
        Write-Host ('decision=' + $gate.decision)
        if ($gate.decision -eq 'PASS') {
            Write-Host 'Result: PASS'
        } else {
            Write-Host ('Blocked by: ' + ($gate.blockers -join '; '))
        }
    }
    default {
        Write-Section 'Full pre-generation flow for xinxin v2.1 (alias)'
        & $runPetWorkflow -RunDir $runRoot -RequireHealthy
        Write-Host "`nGenerating delivery manifest..."
        $pack = & $buildScript -RunDir $runRoot -RequireHealthy
        Write-Host ('artifacts_count=' + $pack.artifacts.Count)
        Write-Host 'Expected assets:'
        foreach ($a in $pack.artifacts) {
            if ($a.required) {
                $exists = if ($a.exists) { 'OK' } else { 'MISS' }
                Write-Host ('- {0} : {1}' -f $a.path, $exists)
            }
        }
        Write-Host "`nThen run visual check by: scripts\run-xinxin-v2.1.ps1 -Mode audit -RunDir .\xinxin-run"
        Write-Host 'When issues appear, follow:'
        Write-Host '- qa\v2.1-failure-remediation-playbook.md'
        Write-Host '- qa\xinxin-v2.1-fast-track-playbook.md'
    }
}
