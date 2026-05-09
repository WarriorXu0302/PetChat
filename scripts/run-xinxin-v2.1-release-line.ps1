param(
    [ValidateSet('baseline', 'gate', 'all')]
    [string]$Line = 'all',
    [string]$RunDir = '.\xinxin-run',
    [switch]$NoFail,
    [string]$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss'),
    [string]$RunIdPrefix = $null,
    [string]$OutputBundleDir = $null,
    [string]$RunLogFile = $null,
    [string]$RunLogSummaryFile = $null,
    [string]$ReleaseGateFile = $null,
    [string]$ReportFile = $null,
    [string]$RecoveryDigestFile = $null,
    [string]$RecoveryDigestMarkdownFile = $null
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$runPetWorkflow = Join-Path $scriptDir 'run-xinxin-v2.1.ps1'
$collectScript = Join-Path $scriptDir 'collect-pet-run-status.ps1'
$collectNextScript = Join-Path $scriptDir 'collect-xinxin-next-artifacts.ps1'
$collectSummaryScript = Join-Path $scriptDir 'summarize-xinxin-recovery.ps1'
$inferRemediationScript = Join-Path $scriptDir 'infer-xinxin-remediation-plan.ps1'

if (-not (Test-Path $runPetWorkflow)) {
    throw "Required script missing: $runPetWorkflow"
}
if (-not (Test-Path $collectScript)) {
    throw "Required script missing: $collectScript"
}
if (-not (Test-Path $collectNextScript)) {
    throw "Required script missing: $collectNextScript"
}
if (-not (Test-Path $inferRemediationScript)) {
    throw "Required script missing: $inferRemediationScript"
}
if (-not (Test-Path $collectSummaryScript)) {
    throw "Required script missing: $collectSummaryScript"
}

$runRoot = Resolve-Path $RunDir

function Get-SafeToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value -replace '[\\/:*?"<>|\s]+', '_')
}

function Add-StepResult {
    param(
        [string]$Name,
        [bool]$Pass,
        [string]$Message = $null,
        [string]$OutputPath = $null
    )
    $result.steps += [ordered]@{
        name = $Name
        status = if ($Pass) { 'pass' } else { 'fail' }
        message = $Message
        output = $OutputPath
        ts = Get-Date -Format 'o'
    }
}

function New-RunLineFailure {
    param(
        [string]$Message,
        [string[]]$Hints = @()
    )
    Write-Error $Message
    foreach ($hint in $Hints) {
        $result.failure_hints += $hint
    }
    Add-StepResult -Name 'release-line' -Pass:$false -Message $Message
    $result.summary = @{
        pass = $false
        message = $Message
        exit_code = 1
    }
    $result.finished_at = Get-Date -Format 'o'
    if ($result.outputs -and $result.outputs.recovery_digest) {
        $result.outputs.recovery_digest = [string]$RecoveryDigestFile
    }
    $result | ConvertTo-Json -Depth 20 | Set-Content -Path $ReportFile -Encoding UTF8
    throw $Message
}

function Add-RecoveryDigest {
    param(
        [string]$ReportPath,
        [string]$BundleDir,
        [string]$Prefix
    )
    $summaryFile = if ($RecoveryDigestFile) { $RecoveryDigestFile } else { Join-Path $BundleDir 'recovery-digest.json' }
    $summaryMarkdown = if ($RecoveryDigestMarkdownFile) { $RecoveryDigestMarkdownFile } else { Join-Path $BundleDir 'recovery-digest.md' }
    Add-StepResult -Name 'build recovery digest' -Pass:$true -Message "writing recovery digest => $summaryFile"
    $args = @(
        '-ReportPath', $ReportPath,
        '-RunDir', $BundleDir,
        '-RunIdPrefix', $Prefix,
        '-OutputPath', $summaryFile,
        '-MarkdownOutputPath', $summaryMarkdown
    )
    try {
        & $collectSummaryScript @args | Out-Null
        $result.outputs.recovery_digest = $summaryFile
        $result.outputs.recovery_digest_markdown = $summaryMarkdown
    } catch {
        $result.failure_hints += "failed to build recovery digest: $($_.Exception.Message)"
    }
}

function New-NextActionFile {
    param(
        [string]$ReportInput,
        [string]$OutputPath,
        [string]$Prefix
    )
    $resolver = Join-Path $scriptDir 'resolve-xinxin-next-action.ps1'
    if (-not (Test-Path $resolver)) {
        $result.failure_hints += 'resolve-xinxin-next-action.ps1 missing, skip next-action markdown'
        return
    }
    if (-not (Test-Path $ReportInput)) {
        $result.failure_hints += "report missing for next-action recommendation: $ReportInput"
        return
    }
    try {
        & $resolver -ReportPath $ReportInput -RunIdPrefix $Prefix -MarkdownOutputPath $OutputPath | Out-Null
    } catch {
        $result.failure_hints += "failed to generate next-action recommendation markdown: $($_.Exception.Message)"
    }
}

$runRootPath = $runRoot.Path
$safeRunId = Get-SafeToken $RunId
$safeRunIdPrefix = Get-SafeToken $RunIdPrefix
if (-not [string]::IsNullOrWhiteSpace($RunIdPrefix)) {
    $safeRunId = "$safeRunIdPrefix-$safeRunId"
}

$bundleDir = if ([string]::IsNullOrWhiteSpace($OutputBundleDir)) {
    Join-Path (Join-Path $runRootPath 'qa') ("release-line-${safeRunId}")
} else {
    $OutputBundleDir
}

if (-not (Test-Path $bundleDir)) {
    New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
}

$runLogFileBase = 'run-log.md'
$runLogSummaryFileBase = 'run-log-summary.json'
$releaseGateFileBase = 'release-gate.json'
$reportFileBase = 'release-line-report.json'
$statusFileBase = 'pipeline-status.json'
$collectOutputPathBase = 'next-action-collect.json'
$remediationPlanPathBase = 'remediation-plan.json'
$remediationPlanMarkdownPathBase = 'remediation-plan.md'
$nextActionFileBase = 'next-action-recommendation.md'

if (-not $RunLogFile) { $RunLogFile = Join-Path $bundleDir $runLogFileBase }
if (-not $RunLogSummaryFile) { $RunLogSummaryFile = Join-Path $bundleDir $runLogSummaryFileBase }
if (-not $ReleaseGateFile) { $ReleaseGateFile = Join-Path $bundleDir $releaseGateFileBase }
if (-not $ReportFile) { $ReportFile = Join-Path $bundleDir $reportFileBase }

$collectNextOutputPath = Join-Path $bundleDir $collectOutputPathBase
$remediationPlanPath = Join-Path $bundleDir $remediationPlanPathBase
$remediationPlanMarkdownPath = Join-Path $bundleDir $remediationPlanMarkdownPathBase
$nextActionFile = Join-Path $bundleDir $nextActionFileBase
$statusFile = Join-Path $bundleDir $statusFileBase
$recoveryDigestPath = if ($RecoveryDigestFile) { $RecoveryDigestFile } else { Join-Path $bundleDir 'recovery-digest.json' }
$recoveryDigestMarkdownPath = if ($RecoveryDigestMarkdownFile) { $RecoveryDigestMarkdownFile } else { Join-Path $bundleDir 'recovery-digest.md' }

$result = [ordered]@{
    schema_version = 'xinxin-v2.1-release-line/1.1'
    started_at = Get-Date -Format 'o'
    run_dir = $runRootPath
    output_bundle_dir = $bundleDir
    line = $Line
    run_id = $safeRunId
    run_id_prefix = if ([string]::IsNullOrWhiteSpace($RunIdPrefix)) { $null } else { $safeRunIdPrefix }
    steps = @()
    failure_hints = @()
    outputs = [ordered]@{
        run_log = $RunLogFile
        run_log_summary = $RunLogSummaryFile
        release_gate = $ReleaseGateFile
        report = $ReportFile
        next_action_collect = $collectNextOutputPath
        remediation_plan = $remediationPlanPath
        remediation_plan_markdown = $remediationPlanMarkdownPath
        next_action = $nextActionFile
        pipeline_status = $statusFile
        recovery_digest = $recoveryDigestPath
        recovery_digest_markdown = $recoveryDigestMarkdownPath
    }
    remediation_plan_steps = 0
    remediation_validation_hint = ''
    health_status = 'unknown'
    health_score = 0
    needs_attention = $false
    health_reasons = @()
}

$safePrefixForCommand = if ([string]::IsNullOrWhiteSpace($safeRunIdPrefix)) { '' } else { $safeRunIdPrefix }

try {
    Write-Host "`n=== Xinxin v2.1 release line ==="
    Write-Host "run_dir=$runRootPath"
    Write-Host "line=$Line"
    Write-Host "run_id=$safeRunId"

    Write-Host '`n[1/2] running all mode with review-ready logging'
    $runArgs = @(
        '-Mode', 'all',
        '-RunDir', $runRootPath,
        '-RunLogOutputFile', $RunLogFile,
        '-RunLogSummaryFile', $RunLogSummaryFile
    )
    if ($Line -ne 'baseline') {
        $runArgs += '-RequireReleaseGate'
        $runArgs += '-ReviewRunLog'
    }
    $runArgs += '-ReleaseGateOutputFile', $ReleaseGateFile

    & $runPetWorkflow @runArgs
    Add-StepResult -Name 'run-xinxin-v2.1 all with optional release gate' -Pass:$true -Message 'completed' -OutputPath $RunLogFile

    Write-Host "`n[2/2] collecting pipeline status snapshot"
    $status = & $collectScript -RunDir $runRootPath
    $status | ConvertTo-Json -Depth 10 | Set-Content -Path $statusFile -Encoding UTF8
    Add-StepResult -Name 'collect status' -Pass:$true -Message ('issues=' + $status.issues.Count) -OutputPath $statusFile

    if ($status.issues.Count -gt 0) {
        $result.failure_hints += 'run-status contains blocking issues; baseline/gate execution may not be reliable.'
    }

    $collectNextSummary = $null
    $collectNextArgs = @(
        '-RunDir', $runRootPath,
        '-RunIdPrefix', $safeRunIdPrefix,
        '-OutputPath', $collectNextOutputPath
    )
    try {
        if ($Line -eq 'gate') {
            $collectNextArgs += '-FailOnAttention'
        }
        if ($Line -ne 'baseline') {
            $collectNextArgs += '-FailOnCritical'
            $collectNextArgs += '-MinHealthScore'
            $collectNextArgs += 70
        }
        $collectNextOutput = & $collectNextScript @collectNextArgs
        if ($collectNextOutput) {
            $collectNextSummary = $collectNextOutput | ConvertFrom-Json
        }
        if (Test-Path $collectNextOutputPath) {
            $result.health_status = if ($collectNextSummary.health_status) { [string]$collectNextSummary.health_status } else { 'unknown' }
            $result.health_score = if ($null -ne $collectNextSummary.health_score) { [int]$collectNextSummary.health_score } else { 0 }
            $result.needs_attention = if ($null -ne $collectNextSummary.needs_attention) { [bool]$collectNextSummary.needs_attention } else { $false }
            $result.health_reasons = if ($collectNextSummary.health_reasons) { @($collectNextSummary.health_reasons) } else { @() }
            Add-StepResult -Name 'collect next-action artifacts' -Pass:$true -Message ('health_status=' + $result.health_status) -OutputPath $collectNextOutputPath
        } else {
            Add-StepResult -Name 'collect next-action artifacts' -Pass:$false -Message 'collect output missing'
            $result.failure_hints += "collect next-action output missing: $collectNextOutputPath"
        }
    } catch {
        Add-StepResult -Name 'collect next-action artifacts' -Pass:$false -Message $_.Exception.Message -OutputPath $collectNextOutputPath
        $result.failure_hints += "collect next-action failed: $($_.Exception.Message)"
        $result.needs_attention = $true
    }

    try {
        if (Test-Path $collectNextOutputPath) {
            $remediationOutput = & $inferRemediationScript -CollectPath $collectNextOutputPath -RunIdPrefix $safeRunIdPrefix -OutputPath $remediationPlanPath -MarkdownOutputPath $remediationPlanMarkdownPath
            if ($remediationOutput) {
                $remediationSummary = $remediationOutput | ConvertFrom-Json
                $result.remediation_plan_steps = if ($remediationSummary -and $remediationSummary.remediation_plan) { $remediationSummary.remediation_plan.Count } else { 0 }
                $result.remediation_validation_hint = if ($remediationSummary -and $remediationSummary.validation_hint) { $remediationSummary.validation_hint } else { '' }
                Add-StepResult -Name 'infer remediation plan' -Pass:$true -Message ('steps=' + $result.remediation_plan_steps) -OutputPath $remediationPlanPath
            } else {
                Add-StepResult -Name 'infer remediation plan' -Pass:$false -Message 'no remediation output'
                $result.failure_hints += "empty remediation plan output from $remediationPlanPath"
            }
        } else {
            Add-StepResult -Name 'infer remediation plan' -Pass:$false -Message 'collect output missing'
        }
    } catch {
        Add-StepResult -Name 'infer remediation plan' -Pass:$false -Message $_.Exception.Message -OutputPath $remediationPlanPath
        $result.failure_hints += "remediation inference failed: $($_.Exception.Message)"
    }

    $gatePass = $true
    if ($Line -ne 'baseline') {
        if (Test-Path $ReleaseGateFile) {
            try {
                $gateData = Get-Content -Raw $ReleaseGateFile | ConvertFrom-Json
                $gatePass = ($gateData.decision -eq 'PASS')
                if (-not $gatePass) {
                    $result.failure_hints += 'release-gate is not PASS. Check qa/checklist, manual review, and run-log. Please rerun with -Line gate.'
                }
            } catch {
                $gatePass = $false
                $result.failure_hints += "failed to parse release gate output: $ReleaseGateFile"
            }
        } else {
            $gatePass = $false
            $result.failure_hints += "missing release gate output: $ReleaseGateFile"
        }
    }

    $result.summary = @{
        pass = if ($Line -ne 'baseline') { $gatePass } else { $true }
        gate_required = ($Line -ne 'baseline')
        gate_pass = if ($Line -ne 'baseline') { $gatePass } else { $null }
        artifacts = @(
            $RunLogFile,
            $RunLogSummaryFile,
            $ReleaseGateFile,
            $statusFile,
            $collectNextOutputPath,
            $remediationPlanPath,
            $remediationPlanMarkdownPath,
            $nextActionFile
        )
        pass_count = ($result.steps | Where-Object { $_.status -eq 'pass' }).Count
        fail_count = ($result.steps | Where-Object { $_.status -eq 'fail' }).Count
        health_status = $result.health_status
        health_score = $result.health_score
        needs_attention = $result.needs_attention
    }

    if (-not (Test-Path $RunLogFile)) {
        New-RunLineFailure "Missing run-log output: $RunLogFile" @(
            "Use output bundle path from -OutputBundleDir or default: .\xinxin-run\qa\release-line-<run-id>"
        )
    }
    if (-not (Test-Path $RunLogSummaryFile)) {
        New-RunLineFailure "Missing run-log summary output: $RunLogSummaryFile" @(
            'Check run-xinxin-v2.1.ps1 -RunLogSummaryFile parameter override.'
        )
    }
    if ($Line -ne 'baseline' -and -not (Test-Path $ReleaseGateFile)) {
        New-RunLineFailure "Missing release gate output: $ReleaseGateFile" @(
            "Use Line=gate and ensure run-xinxin-v2.1.ps1 emits release gate output via -ReleaseGateOutputFile."
        )
    }

    New-NextActionFile -ReportInput $ReportFile -OutputPath $nextActionFile -Prefix $safeRunIdPrefix
    Add-StepResult -Name 'generate next-action markdown' -Pass:($true) -Message $nextActionFile -OutputPath $nextActionFile
    Add-RecoveryDigest -ReportPath $ReportFile -BundleDir $bundleDir -Prefix $safeRunIdPrefix

    $result.finished_at = Get-Date -Format 'o'
    $result | ConvertTo-Json -Depth 20 | Set-Content -Path $ReportFile -Encoding UTF8

    Write-Host "`n=== release line completed ==="
    Write-Host "report=$ReportFile"
    Write-Host "run_log=$RunLogFile"
    Write-Host "summary=$RunLogSummaryFile"
    if ($Line -ne 'baseline') { Write-Host "release_gate=$ReleaseGateFile" }
    Write-Host "recovery_digest=$recoveryDigestPath"
}
catch {
    if ($NoFail) {
        Write-Warning $_.Exception.Message
        if ($result.failure_hints.Count -eq 0) {
            $result.failure_hints += 'unexpected release-line failure; rerun with default baseline/all first, then gate.'
            $result.failure_hints += 'If still failing, run with -NoFail and read report + next-action outputs.'
        }
        if (-not $result.finished_at) {
            $result.finished_at = Get-Date -Format 'o'
        }
        if (-not $result.summary) {
            $result.summary = @{
                pass = $false
                gate_required = $true
                message = $_.Exception.Message
                exit_code = 1
            }
        }
        $result.outputs.recovery_digest = $recoveryDigestPath
        if (-not (Test-Path $recoveryDigestPath)) {
            Add-RecoveryDigest -ReportPath $ReportFile -BundleDir $bundleDir -Prefix $safeRunIdPrefix
        }
        $result | ConvertTo-Json -Depth 20 | Set-Content -Path $ReportFile -Encoding UTF8
        exit 0
    }
    throw
}
