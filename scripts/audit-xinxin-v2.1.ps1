param(
    [string]$RunDir = '.\xinxin-run',
    [string]$OutputFile = $null,
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runRoot = Resolve-Path $RunDir
$scriptDir = Split-Path -Parent $PSCommandPath
$collectScript = Join-Path $scriptDir 'collect-pet-run-status.ps1'
$buildScript = Join-Path $scriptDir 'build-xinxin-delivery-manifest.ps1'

if (-not (Test-Path $collectScript)) {
    throw "Required script missing: $collectScript"
}
if (-not (Test-Path $buildScript)) {
    throw "Required script missing: $buildScript"
}

function New-AuditItem {
    param(
        [string]$name,
        [string]$status,
        [string]$message,
        [string]$severity = 'medium'
    )
    return [ordered]@{
        name = $name
        status = $status
        message = $message
        severity = $severity
    }
}

function New-StateItem {
    param(
        [string]$state,
        [string]$status,
        [int]$expected_frames,
        [int]$actual_frames,
        [string]$message = ''
    )
    return [ordered]@{
        state = $state
        status = $status
        expected_frames = $expected_frames
        actual_frames = $actual_frames
        message = $message
    }
}

$status = & $collectScript -RunDir $runRoot -NoWrite:$true
$pack = & $buildScript -RunDir $runRoot -NoWrite

$petRequest = $null
$petRequestPath = Join-Path $runRoot 'pet_request.json'
if (Test-Path $petRequestPath) {
    try {
        $petRequest = Get-Content $petRequestPath -Raw | ConvertFrom-Json
    } catch {
        $petRequest = $null
    }
}

$validation = $null
$validationPath = Join-Path $runRoot 'final\validation.json'
if (Test-Path $validationPath) {
    try {
        $validation = Get-Content $validationPath -Raw | ConvertFrom-Json
    } catch {
        $validation = $null
    }
}

$expectedFramesByState = @{}
foreach ($row in $status.checks.frames) {
    $expectedFramesByState[[string]$row.state] = [int]$row.expected_frames
}

$checks = @()
$checks += New-AuditItem -name 'pipeline_health' -status $(if($status.state -eq 'healthy'){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('Pipeline state is {0}.' -f $status.state)
$checks += New-AuditItem -name 'issues_blocking' -status $(if($status.issues.Count -eq 0){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('Issues: {0}' -f $status.issues.Count)
$checks += New-AuditItem -name 'warnings_present' -status $(if($status.warnings.Count -eq 0){ 'PASS' } else { 'WARN' }) -severity 'medium' -message ('Warnings: {0}' -f $status.warnings.Count)
$checks += New-AuditItem -name 'frame_completion_ratio' -status $(if(($status.summary.frame_completion_ratio) -eq 100){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('Frame completion ratio is {0}%%.' -f $status.summary.frame_completion_ratio -replace '%%','%')
$checks += New-AuditItem -name 'job_completion_ratio' -status $(if(($status.summary.jobs_completion_ratio) -eq 100){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('Job completion ratio is {0}%%.' -f $status.summary.jobs_completion_ratio -replace '%%','%')
$checks += New-AuditItem -name 'required_artifacts' -status $(if($pack.checks.package_readiness -eq 100){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('Required files ready: {0}/{1}.' -f $pack.checks.present_required_files, $pack.checks.required_files)
$checks += New-AuditItem -name 'validation_file' -status $(if($null -ne $validation){ if($validation.ok){ 'PASS' } else { 'FAIL' } } else { 'FAIL' }) -severity 'high' -message ('Validation file exists: {0}.' -f ($null -ne $validation))

$stateMatrix = @()
foreach ($state in $status.checks.frames | Sort-Object -Property state) {
    $statusValue = if ($state.status -eq 'ok') { 'PASS' } else { 'FAIL' }
    $stateMatrix += New-StateItem -state $state.state -status $statusValue -expected_frames ([int]$state.expected_frames) -actual_frames ([int]$state.actual_frames) -message $state.status
}
$statePassCount = @($stateMatrix | Where-Object { $_.status -eq 'PASS' }).Count
$checks += New-AuditItem -name 'state_matrix' -status $(if($statePassCount -eq $stateMatrix.Count){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('State pass count: {0}/{1}.' -f $statePassCount, $stateMatrix.Count)

$validationMatrix = @()
if ($null -ne $validation -and $validation.PSObject.Properties.Name -contains 'cells') {
    $validationUsedByState = @{}
    $validationZeroContent = 0
    foreach ($cell in $validation.cells) {
        if ($null -ne $cell.state -and ($cell.state -ne '')) {
            $key = [string]$cell.state
            if (-not $validationUsedByState.ContainsKey($key)) {
                $validationUsedByState[$key] = 0
            }
            if ($cell.used) {
                $validationUsedByState[$key] += 1
            }
        }
        if (($cell.used -eq $true) -and ($cell.nontransparent_pixels -le 0)) {
            $validationZeroContent++
        }
    }

    foreach ($state in $expectedFramesByState.Keys | Sort-Object) {
        $expected = $expectedFramesByState[$state]
        $actualUsed = if ($validationUsedByState.ContainsKey($state)) { [int]$validationUsedByState[$state] } else { 0 }
        $validationMatrix += New-StateItem -state $state -status $(if($actualUsed -eq $expected){ 'PASS' } else { 'FAIL' }) -expected_frames $expected -actual_frames $actualUsed -message ('Validation used cells')
    }

    $unexpectedStateUsed = 0
    foreach ($state in $validationUsedByState.Keys) {
        if (-not $expectedFramesByState.ContainsKey($state)) {
            $unexpectedStateUsed += $validationUsedByState[$state]
        }
    }

    $checks += New-AuditItem -name 'validation_state_slots' -status $(if(@($validationMatrix | Where-Object { $_.status -ne 'PASS' }).Count -eq 0){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('Validation state slots pass: {0}/{1}.' -f (@($validationMatrix | Where-Object { $_.status -eq 'PASS' }).Count), $validationMatrix.Count)
    $checks += New-AuditItem -name 'validation_zero_content_frames' -status $(if($validationZeroContent -eq 0){ 'PASS' } else { 'FAIL' }) -severity 'medium' -message ('Used frames with zero nontransparent pixels: {0}.' -f $validationZeroContent)
    $checks += New-AuditItem -name 'validation_unknown_state_frames' -status $(if($unexpectedStateUsed -eq 0){ 'PASS' } else { 'WARN' }) -severity 'medium' -message ('Used cells in unknown states: {0}.' -f $unexpectedStateUsed)

    if ($petRequest -and $petRequest.PSObject.Properties.Name -contains 'atlas' -and $petRequest.atlas -and $validation.PSObject.Properties.Name -contains 'width') {
        $atlasWidth = [int]$petRequest.atlas.width
        $atlasHeight = [int]$petRequest.atlas.height
        $dimensionPass = ($validation.width -eq $atlasWidth) -and ($validation.height -eq $atlasHeight)
        $checks += New-AuditItem -name 'validation_dimensions' -status $(if($dimensionPass){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('Validation vs atlas: {0}x{1} vs {2}x{3}.' -f $validation.width, $validation.height, $atlasWidth, $atlasHeight)
    } else {
        $checks += New-AuditItem -name 'validation_dimensions' -status 'WARN' -severity 'medium' -message 'Atlas metadata missing or incomplete in pet_request.json.'
    }
} else {
    $checks += New-AuditItem -name 'validation_state_slots' -status 'FAIL' -severity 'high' -message 'validation.json missing or unparsable; validation matrix unavailable.'
}

$artifactMatrix = @()
foreach ($artifact in @($pack.artifacts | Where-Object { $_.required })) {
    $artifactPass = $artifact.exists -and ($artifact.size_bytes -gt 0)
    $artifactMatrix += [ordered]@{
        name = $artifact.name
        status = if ($artifactPass) { 'PASS' } else { 'FAIL' }
        path = $artifact.path
        exists = $artifact.exists
        size_bytes = if ($artifact.exists) { $artifact.size_bytes } else { 0 }
    }
}
$artifactPassCount = @($artifactMatrix | Where-Object { $_.status -eq 'PASS' }).Count
$checks += New-AuditItem -name 'required_artifact_matrix' -status $(if($artifactPassCount -eq $artifactMatrix.Count){ 'PASS' } else { 'FAIL' }) -severity 'high' -message ('Required artifact pass count: {0}/{1}.' -f $artifactPassCount, $artifactMatrix.Count)

$failCount = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count
$warnCount = @($checks | Where-Object { $_.status -eq 'WARN' }).Count
$passCount = @($checks | Where-Object { $_.status -eq 'PASS' }).Count
$overall = if ($failCount -gt 0) { 'FAIL' } else { 'PASS' }

$qaDir = Join-Path $runRoot 'qa'
if (-not $OutputFile) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputFile = Join-Path $qaDir ('run-audit-{0}.json' -f $timestamp)
}

if (-not $NoWrite) {
    if (-not (Test-Path $qaDir)) {
        New-Item -ItemType Directory -Path $qaDir -Force | Out-Null
    }
    $payload = [ordered]@{
        generated_at = [DateTime]::UtcNow.ToString('o')
        run_dir = $runRoot.Path
        pet_id = $status.pet_id
        status = $status
        checks = $checks
        state_matrix = $stateMatrix
        validation_matrix = $validationMatrix
        required_artifact_matrix = $artifactMatrix
        manual_review = [ordered]@{
            status = 'PENDING'
            contact_sheet = (Test-Path (Join-Path $qaDir 'contact-sheet.png'))
            review_sheet = (Test-Path (Join-Path $qaDir 'review.json'))
            notes = 'Manual visual and identity consistency review is still required for IP freeze.'
        }
        summary = [ordered]@{
            overall = $overall
            total_checks = $checks.Count
            pass_checks = $passCount
            warn_checks = $warnCount
            fail_checks = $failCount
        }
    }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding utf8
}

$audit = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    run_dir = $runRoot.Path
    pet_id = $status.pet_id
    status = $status
    checks = $checks
    state_matrix = $stateMatrix
    validation_matrix = $validationMatrix
    required_artifact_matrix = $artifactMatrix
    manual_review = [ordered]@{
        status = 'PENDING'
        contact_sheet = (Test-Path (Join-Path $qaDir 'contact-sheet.png'))
        review_sheet = (Test-Path (Join-Path $qaDir 'review.json'))
        notes = 'Manual visual and identity consistency review is still required for IP freeze.'
    }
    summary = [ordered]@{
        overall = $overall
        total_checks = $checks.Count
        pass_checks = $passCount
        warn_checks = $warnCount
        fail_checks = $failCount
    }
    output_file = $OutputFile
}

$audit
