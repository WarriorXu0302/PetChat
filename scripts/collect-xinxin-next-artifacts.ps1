param(
    [string]$RunDir = '.\xinxin-run',
    [string]$RunIdPrefix = '',
    [string]$OutputPath = $null,
    [switch]$HumanReadable,
    [switch]$FailOnAttention,
    [switch]$FailOnCritical,
    [int]$MinHealthScore = 0
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

function Find-LatestArtifact {
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
        $filtered = $files | Where-Object { ($_.Name -like "*$Contains*") -or ($_.FullName -like "*$Contains*") }
        if ($filtered.Count -gt 0) {
            $files = $filtered
        }
    }
    if ($files.Count -eq 0) {
        return $null
    }

    return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
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

function New-HealthState {
    return [ordered]@{
        score = 100
        status = 'healthy'
        needs_attention = $false
        reasons = [System.Collections.Generic.List[string]]::new()
    }
}

function Add-HealthReason {
    param(
        [psobject]$State,
        [string]$Message,
        [int]$Penalty = 5,
        [bool]$Critical = $false
    )
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }
    $State.reasons.Add($Message)
    $State.score = [Math]::Max(0, $State.score - $Penalty)
    if ($Critical) {
        $State.needs_attention = $true
    }
}

function Finalize-HealthState {
    param([psobject]$State)

    if ($State.reasons.Count -eq 0) {
        $State.status = 'healthy'
    } elseif ($State.score -ge 80) {
        $State.status = 'warning'
    } else {
        $State.status = 'critical'
    }

    if ($State.status -ne 'healthy') {
        $State.needs_attention = $true
    }
}

$safeRunIdPrefix = Get-SafeToken $RunIdPrefix
$runDirPath = (Resolve-Path $RunDir -ErrorAction SilentlyContinue).Path
if (-not $runDirPath) {
    throw "RunDir not found: $RunDir"
}
$qaDir = Join-Path $runDirPath 'qa'
if (-not (Test-Path $qaDir)) {
    $qaDir = $runDirPath
}

$reportPath = Find-LatestArtifact -RootDir $qaDir -NamePattern 'release-line-report.json' -Contains $safeRunIdPrefix
$releaseGatePath = Find-LatestArtifact -RootDir $qaDir -NamePattern 'release-gate*.json' -Contains $safeRunIdPrefix
$runStatusPath = Find-LatestArtifact -RootDir $qaDir -NamePattern 'run-status.json' -Contains $safeRunIdPrefix
$runLogSummaryPath = Find-LatestArtifact -RootDir $qaDir -NamePattern '*-summary.json' -Contains $safeRunIdPrefix
$runLogPath = Find-LatestArtifact -RootDir $qaDir -NamePattern 'run-log*.md' -Contains $safeRunIdPrefix
$nextActionPath = Find-LatestArtifact -RootDir $qaDir -NamePattern 'next-action-recommendation.md' -Contains $safeRunIdPrefix

if (-not $nextActionPath) {
    $nextActionPath = Join-Path $qaDir 'next-action-recommendation.md'
}

$resolver = Join-Path (Split-Path $MyInvocation.MyCommand.Path) 'resolve-xinxin-next-action.ps1'
$nextResult = $null
if ($reportPath) {
    $nextOutput = & $resolver -ReportPath $reportPath -RunIdPrefix $safeRunIdPrefix -MarkdownOutputPath $nextActionPath
    if ($nextOutput) {
        $nextResult = $nextOutput | ConvertFrom-Json
    }
} elseif ($releaseGatePath -or $runStatusPath) {
    $resolverArgs = @('-RunIdPrefix', $safeRunIdPrefix, '-MarkdownOutputPath', $nextActionPath)
    if ($releaseGatePath) { $resolverArgs += @('-ReleaseGatePath', $releaseGatePath) }
    if ($runStatusPath) { $resolverArgs += @('-RunStatusPath', $runStatusPath) }
    $nextOutput = & $resolver @resolverArgs
    if ($nextOutput) {
        $nextResult = $nextOutput | ConvertFrom-Json
    }
}

$summary = [ordered]@{
    timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    run_dir = $runDirPath
    run_id_prefix = if ([string]::IsNullOrWhiteSpace($safeRunIdPrefix)) { $null } else { $safeRunIdPrefix }
    artifacts = [ordered]@{
        report = $reportPath
        release_gate = $releaseGatePath
        run_status = $runStatusPath
        run_log = $runLogPath
        run_log_summary = $runLogSummaryPath
        next_action_recommendation = $nextActionPath
    }
    next_action = $nextResult
    next_action_sources = @{
        has_report = [bool]($reportPath)
        has_release_gate = [bool]($releaseGatePath)
        has_run_status = [bool]($runStatusPath)
    }
    next_action_command = if ($nextResult) { $nextResult.recommended_command } else { '' }
    next_action_step = if ($nextResult) { $nextResult.recommended_step } else { 'unknown' }
    next_action_reason = if ($nextResult) { $nextResult.reason } else { 'next-action resolution missing' }
}

if ($nextResult -and $nextResult.schema_validation) {
    $summary.next_action_schema = $nextResult.schema_validation
} else {
    $summary.next_action_schema = [ordered]@{
        schema_version = 'xinxin-next-action/1.1'
        source = 'unknown'
        valid = $false
        errors = @('next-action resolver output unavailable')
        warnings = @()
        checks = @()
    }
}

if ($nextActionPath -and (Test-Path $nextActionPath)) {
    $summary.next_action_markdown_exists = $true
    $summary.next_action_markdown_length = (Get-Item $nextActionPath).Length
    } else {
        $summary.next_action_markdown_exists = $false
        $summary.next_action_markdown_length = 0
    }

$health = New-HealthState
$artifactCoverage = @(
    [bool]($reportPath),
    [bool]($releaseGatePath),
    [bool]($runStatusPath)
)
if (-not ($artifactCoverage -contains $true)) {
    Add-HealthReason -State $health -Message 'missing release report, release-gate, and run-status artifacts' -Penalty 100 -Critical $true
}

if (-not $nextResult) {
    Add-HealthReason -State $health -Message 'next-action resolver output missing' -Penalty 100 -Critical $true
} else {
    if ($nextResult.schema_validation) {
        if (-not $nextResult.schema_validation.valid) {
            Add-HealthReason -State $health -Message "schema invalid: $($nextResult.schema_validation.errors -join '; ')" -Penalty 55 -Critical $true
        } elseif ($nextResult.schema_validation.warnings -and $nextResult.schema_validation.warnings.Count -gt 0) {
            Add-HealthReason -State $health -Message "schema warnings: $($nextResult.schema_validation.warnings -join '; ')" -Penalty 10
        }

        if ($nextResult.recommended_step -ne 'passed' -and [string]::IsNullOrWhiteSpace($nextResult.recommended_command)) {
            Add-HealthReason -State $health -Message "next action step '$($nextResult.recommended_step)' requires recovery but no command was produced" -Penalty 20
        }
        if ($nextResult.recommended_step -eq 'passed' -and -not [string]::IsNullOrWhiteSpace($nextResult.recommended_command)) {
            Add-HealthReason -State $health -Message "recommendation marked passed but command still exists" -Penalty 5
        }
    } else {
        Add-HealthReason -State $health -Message 'schema_validation section missing in next-action output' -Penalty 45 -Critical $true
    }
}

if ($summary.next_action_markdown_exists -eq $false) {
    Add-HealthReason -State $health -Message "next-action recommendation markdown missing: $nextActionPath" -Penalty 10
} elseif ($summary.next_action_markdown_length -eq 0) {
    Add-HealthReason -State $health -Message 'next-action recommendation markdown is empty' -Penalty 10
}

Finalize-HealthState -State $health

$summary.health_status = $health.status
$summary.health_score = $health.score
$summary.needs_attention = $health.needs_attention
$summary.health_reasons = @($health.reasons)

if ($HumanReadable) {
    Write-Host 'xinxin next-action artifact snapshot'
    Write-Host "run_dir=$($summary.run_dir)"
    Write-Host "run_id_prefix=$($summary.run_id_prefix)"
    Write-Host "next_action=$($summary.next_action_step) | reason=$($summary.next_action_reason)"
    Write-Host "recommended_command=$($summary.next_action_command)"
    Write-Host "next_action_markdown=$($nextActionPath)"
    Write-Host "schema_valid=$($summary.next_action_schema.valid)"
    Write-Host 'artifacts:'
    foreach ($item in $summary.artifacts.GetEnumerator()) {
        Write-Host ("  {0}: {1}" -f $item.Key, $item.Value)
    }
    Write-Host "health_status=$($summary.health_status) score=$($summary.health_score) needs_attention=$($summary.needs_attention)"
    if ($summary.health_reasons -and $summary.health_reasons.Count -gt 0) {
        Write-Host 'health_reasons:'
        foreach ($reason in $summary.health_reasons) {
            Write-Host ("  - $reason")
        }
    }
}

$healthGate = [ordered]@{
    enabled = [ordered]@{
        fail_on_attention = [bool]$FailOnAttention.IsPresent
        fail_on_critical = [bool]$FailOnCritical.IsPresent
        min_health_score = $MinHealthScore
    }
    blocked = $false
    reasons = [System.Collections.Generic.List[string]]::new()
}

if ($FailOnAttention -and $summary.needs_attention) {
    $healthGate.blocked = $true
    $healthGate.reasons.Add('fails because needs_attention is true')
}
if ($FailOnCritical -and $summary.health_status -eq 'critical') {
    $healthGate.blocked = $true
    $healthGate.reasons.Add('fails because health_status is critical')
}
if ($MinHealthScore -gt 0 -and $summary.health_score -lt $MinHealthScore) {
    $healthGate.blocked = $true
    $healthGate.reasons.Add("fails because health_score $($summary.health_score) < min $MinHealthScore")
}

$summary.health_gate = [ordered]@{
    enabled = $healthGate.enabled
    blocked = $healthGate.blocked
    reasons = @($healthGate.reasons)
}

if ($OutputPath) {
    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
}

$summaryJson = $summary | ConvertTo-Json -Depth 10
Write-Output $summaryJson

if ($healthGate.blocked) {
    throw ("collect-xinxin-next-artifacts health gate failed: " + ($healthGate.reasons -join '; '))
}
