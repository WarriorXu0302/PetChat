param(
    [string]$RunDir = '.\xinxin-run',
    [string]$RunIdPrefix = 'release-cycle',
    [string]$OutputRoot = '.\xinxin-run\qa\recovery-cycles',
    [string]$BundleName = '',
    [string]$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss'),
    [string[]]$OnlyPhases = @(),
    [switch]$StopOnFail,
    [switch]$Force,
    [switch]$SkipBoard,
    [switch]$NoBoardOnFail,
    [ValidateSet('json', 'markdown', 'both')]
    [string]$ReportFormat = 'json',
    [switch]$EmitGithubOutputs,
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

function Write-OutputIfAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Value
    )
    if (-not $Name) {
        return
    }
    $safeValue = if ($null -eq $Value) { '' } else { [string]$Value }
    Write-Host "$Name=$safeValue"
    if ($EmitGithubOutputs -or $env:GITHUB_OUTPUT) {
        if ($env:GITHUB_OUTPUT) {
            $githubOutputFile = $env:GITHUB_OUTPUT
            Add-Content -Path $githubOutputFile -Value "$Name=$safeValue"
        } else {
            Write-Host "GITHUB_OUTPUT not set, skip workflow output emission for $Name"
        }
    }
}

function Resolve-PathFromRepo {
    param([string]$PathValue)
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }
    return Join-Path $repoRoot $PathValue
}

$scriptDir = Split-Path -Parent $PSCommandPath
$executeScript = Join-Path $scriptDir 'execute-xinxin-recovery-cycle.ps1'
$boardScript = Join-Path $scriptDir 'build-xinxin-recovery-board.ps1'

foreach ($path in @($executeScript, $boardScript)) {
    if (-not (Test-Path $path)) {
        throw "Required script missing: $path"
    }
}

$safePrefix = Get-SafeToken $RunIdPrefix
$safeRunId = Get-SafeToken $RunId
$runToken = if ($safeRunId) { $safeRunId } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
$bundle = if ([string]::IsNullOrWhiteSpace($BundleName)) { "$safePrefix-$runToken" } else { $BundleName }

$resolvedOutputRoot = Resolve-PathFromRepo -PathValue $OutputRoot
if (-not (Test-Path $resolvedOutputRoot)) {
    New-Item -ItemType Directory -Path $resolvedOutputRoot -Force | Out-Null
}
$cycleDir = Join-Path $resolvedOutputRoot $bundle
$cycleReport = Join-Path $cycleDir 'recovery-cycle-report.json'

$cycleArgs = @(
    '-RunDir', $RunDir,
    '-RunIdPrefix', $safePrefix,
    '-OutputRoot', $OutputRoot,
    '-BundleName', $bundle,
    '-RunId', $runToken,
    '-CycleReportPath', $cycleReport,
)
if ($OnlyPhases -and $OnlyPhases.Count -gt 0) {
    $cycleArgs += '-OnlyPhases'
    $cycleArgs += $OnlyPhases
}
if ($StopOnFail) { $cycleArgs += '-StopOnFail' }
if ($Force) { $cycleArgs += '-Force' }
$cycleArgs += '-NoExit'

Write-Host "=== command-center ==="
Write-Host "recovery_cycle_root=$cycleDir"
Write-Host "command_center_schema_version=xinxin-command-center/1.1"
Write-Host "command_center_report_format=$ReportFormat"

$executionOk = $false
$executionExitCode = 0
$reportedPass = $false
$boardBuilt = $false
$cycle = $null
$boardJsonPath = Join-Path $cycleDir 'release-cycle-board.json'
$boardMarkdownPath = Join-Path $cycleDir 'release-cycle-board.md'
$summaryPath = Join-Path $cycleDir 'command-center-summary.json'
$summaryMarkdownPath = Join-Path $cycleDir 'command-center-summary.md'
try {
    $null = & $executeScript @cycleArgs
    $executionOk = $true
} catch {
    $executionExitCode = 1
    Write-Warning "recovery cycle execution failed: $($_.Exception.Message)"
}

if (Test-Path $cycleReport) {
    Write-Host "cycle_report=$cycleReport"
    try {
        $cycle = Get-Content -Raw -Path $cycleReport | ConvertFrom-Json
        if ($cycle.summary -and $cycle.summary.PSObject.Properties.Name -contains 'pass') {
            $reportedPass = [bool]$cycle.summary.pass
            Write-Host "cycle_pass=$reportedPass"
        } else {
            Write-Warning "cycle report missing summary.pass: $cycleReport"
            $executionExitCode = 1
        }
    } catch {
        Write-Warning "failed to parse cycle report: $($_.Exception.Message)"
        $executionExitCode = 1
    }
} else {
    Write-Warning "cycle report not found yet: $cycleReport"
    $executionExitCode = 1
}

if ($executionOk -and -not $reportedPass) {
    $executionExitCode = 1
}

if ($NoBoardOnFail -and $executionExitCode -ne 0) {
    Write-Host "skip board build by NoBoardOnFail"
    exit $executionExitCode
}

if ($SkipBoard) {
    exit $executionExitCode
}

if (Test-Path $cycleReport) {
    $boardArgs = @(
        '-CycleReportPath', $cycleReport
    )
    if ($HumanReadable) { $boardArgs += '-HumanReadable' }
    try {
        $null = & $boardScript @boardArgs
        $boardBuilt = $true
    } catch {
        Write-Warning "build board failed: $($_.Exception.Message)"
        $executionExitCode = 1
    }
} else {
    Write-Warning "skip board build, missing cycle report: $cycleReport"
    $executionExitCode = 1
}

if ($executionExitCode -ne 0) {
    Write-Warning "command-center finished with failure; see cycle report for details."
}

$summary = [ordered]@{
    schema_version = 'xinxin-command-center/1.1'
    finished_at = Get-Date -Format 'o'
    command = 'run-xinxin-release-command-center.ps1'
    run_dir = $RunDir
    run_id_prefix = $RunIdPrefix
    bundle = $bundle
    cycle_report = $cycleReport
    cycle_root = $cycleDir
    execution = [ordered]@{
        script = 'run-xinxin-release-command-center.ps1'
        executed = $executionOk
        exit_code = $executionExitCode
        only_phases = @($OnlyPhases)
        stop_on_fail = [bool]$StopOnFail
        force = [bool]$Force
    }
    cycle = if ($cycle) {
        [ordered]@{
            pass = $reportedPass
            summary = if ($cycle.summary) { $cycle.summary } else { $null }
            next_action_step = if ($cycle.next_action_step) { [string]$cycle.next_action_step } else { '' }
            next_action_command = if ($cycle.next_action_command) { [string]$cycle.next_action_command } else { '' }
            requested_phase_count = if ($cycle.summary -and $cycle.summary.requested_phase_count -ne $null) { [int]$cycle.summary.requested_phase_count } else { 0 }
            executed_phase_count = if ($cycle.summary -and $cycle.summary.executed_phase_count -ne $null) { [int]$cycle.summary.executed_phase_count } else { 0 }
            failing_phases = if ($cycle.summary -and $cycle.summary.failing_phases) { @($cycle.summary.failing_phases) } else { @() }
            outputs = if ($cycle.outputs) { $cycle.outputs } else { @{} }
            started_at = if ($cycle.started_at) { [string]$cycle.started_at } else { '' }
            finished_at = if ($cycle.finished_at) { [string]$cycle.finished_at } else { '' }
        }
    } else {
        [ordered]@{
            pass = $false
            summary = $null
            next_action_step = ''
            next_action_command = ''
            requested_phase_count = 0
            executed_phase_count = 0
            failing_phases = @()
            outputs = @{}
            started_at = ''
            finished_at = ''
        }
    }
    board = [ordered]@{
        skipped = [bool]$SkipBoard
        skipped_on_fail = [bool]($NoBoardOnFail -and $executionExitCode -ne 0)
        built = [bool]$boardBuilt
        board_json = [string]$boardJsonPath
        board_markdown = [string]$boardMarkdownPath
    }
    human_readable = [bool]$HumanReadable
}

if ($ReportFormat -in @('json', 'both')) {
    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryPath -Encoding UTF8
    Write-OutputIfAvailable -Name 'command_center_summary' -Value $summaryPath
    Write-OutputIfAvailable -Name 'command_center_summary_json' -Value $summaryPath
    Write-OutputIfAvailable -Name 'command_center_summary_path' -Value $summaryPath
}
if ($ReportFormat -in @('markdown', 'both')) {
    $lines = @()
    $lines += '# Xinxin Release Command Center Summary'
    $lines += ''
    $lines += "run_id_prefix: $RunIdPrefix"
    $lines += "bundle: $bundle"
    $lines += "cycle_root: $cycleDir"
    $lines += "cycle_report: $cycleReport"
    $lines += "cycle_pass: $reportedPass"
    $lines += "execution_exit_code: $executionExitCode"
    if ($summary.cycle.summary) {
        $lines += "requested_phases: $($summary.cycle.summary.requested_phase_count)"
        $lines += "executed_phases: $($summary.cycle.summary.executed_phase_count)"
        if ($summary.cycle.failing_phases.Count -gt 0) {
            $lines += "failing_phases: $($summary.cycle.failing_phases -join ', ')"
        }
    }
    if ($summary.cycle.next_action_step) {
        $lines += "next_action_step: $($summary.cycle.next_action_step)"
    }
    if ($summary.cycle.next_action_command) {
        $lines += "next_action_command: $($summary.cycle.next_action_command)"
    }
    $lines += ''
    $lines += "board_built: $boardBuilt"
    if ($SkipBoard) {
        $lines += 'board: skipped'
    } elseif ($NoBoardOnFail -and $executionExitCode -ne 0) {
        $lines += 'board: skipped_on_fail'
    } elseif ($boardBuilt) {
        $lines += "board_json: $boardJsonPath"
        $lines += "board_markdown: $boardMarkdownPath"
    }
    Set-Content -Path $summaryMarkdownPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    Write-OutputIfAvailable -Name 'command_center_summary_markdown' -Value $summaryMarkdownPath
    Write-OutputIfAvailable -Name 'command_center_summary_markdown_path' -Value $summaryMarkdownPath
}
Write-OutputIfAvailable -Name 'cycle_report' -Value $cycleReport
Write-OutputIfAvailable -Name 'cycle_pass' -Value ([string]$reportedPass)
Write-OutputIfAvailable -Name 'cycle_exit_code' -Value ([string]$executionExitCode)
Write-OutputIfAvailable -Name 'command_center_exit_code' -Value ([string]$executionExitCode)
Write-OutputIfAvailable -Name 'command_center_pass' -Value ([string]$reportedPass)
Write-OutputIfAvailable -Name 'cycle_dir' -Value $cycleDir
Write-OutputIfAvailable -Name 'command_center_cycle_root' -Value $cycleDir
Write-OutputIfAvailable -Name 'run_dir' -Value $RunDir
Write-OutputIfAvailable -Name 'run_id_prefix' -Value $RunIdPrefix
Write-OutputIfAvailable -Name 'bundle_name' -Value $bundle
if (Test-Path $boardJsonPath) {
    Write-OutputIfAvailable -Name 'release_cycle_board_json' -Value $boardJsonPath
}
if (Test-Path $boardMarkdownPath) {
    Write-OutputIfAvailable -Name 'release_cycle_board_markdown' -Value $boardMarkdownPath
}
if (Test-Path $summaryPath) {
    Write-OutputIfAvailable -Name 'command_center_summary_exists' -Value 'true'
}
if (Test-Path $summaryMarkdownPath) {
    Write-OutputIfAvailable -Name 'command_center_summary_markdown_exists' -Value 'true'
}

if (-not $env:GITHUB_OUTPUT -and -not $EmitGithubOutputs) {
    Write-Host 'Note: GITHUB_OUTPUT not set; outputs were printed to console only.'
}

exit $executionExitCode
