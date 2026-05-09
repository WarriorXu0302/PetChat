param(
    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-StatusItem {
    param(
        [ref]$target,
        [string]$type,
        [string]$message,
        [string]$path = $null,
        [string]$kind = 'issue'
    )

    $entry = [ordered]@{
        type = $type
        message = $message
    }

    if ($null -ne $path) {
        $entry.path = $path
    }

    if ($kind -eq 'warning') {
        $target.Value += $entry
        return
    }

    $target.Value += $entry
}

function New-ArtifactReport {
    param([string]$name, [string]$path, [bool]$exists, [int]$count = 0)
    return [ordered]@{
        name = $name
        path = $path
        exists = $exists
        file_count = $count
    }
}

$runPath = Resolve-Path $RunDir
$status = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    run_dir = $runPath.Path
    pet_id = $null
    state = 'init'
    checks = [ordered]@{
        directories = [ordered]@{}
        assets = [ordered]@{}
        frames = @()
        required_frame_dirs = @()
        extras = @()
        run_layout = @()
    }
    issues = @()
    warnings = @()
    jobs = [ordered]@{
        total = 0
        complete = 0
        pending = 0
        failed = 0
        paused = 0
    }
    summary = [ordered]@{}
    gate = [ordered]@{
        ready_for_generation = $false
        reasons = @()
    }
}

$requiredDirs = @('decoded', 'frames', 'final', 'qa', 'references', 'prompts')
foreach ($dir in $requiredDirs) {
    $status.checks.directories[$dir] = Test-Path (Join-Path $runPath $dir)
}

$requiredAssets = @('pet_request.json', 'imagegen-jobs.json', 'prompts\base-pet.md')
foreach ($file in $requiredAssets) {
    $status.checks.assets[$file] = Test-Path (Join-Path $runPath $file)
}

$requestedStates = @{}
$expectedStateCount = 0
$expectedFrameCount = 0
$actualFrameCount = 0
$hasRows = $false

$petRequestPath = Join-Path $runPath 'pet_request.json'
if ($status.checks.assets['pet_request.json']) {
    try {
        $petRequest = Get-Content $petRequestPath -Raw | ConvertFrom-Json
        $status.pet_id = $petRequest.pet_id

        if ($petRequest.PSObject.Properties.Name -contains 'rows' -and $null -ne $petRequest.rows) {
            foreach ($row in $petRequest.rows) {
                $hasRows = $true
                if ([string]::IsNullOrWhiteSpace($row.state)) {
                    Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'pet_request_row' -message "Found a row without a valid state token in pet_request.json."
                    continue
                }

                if (($null -eq $row.frames) -or ($row.frames -lt 0)) {
                    Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'pet_request_row_frames' -message "State '$($row.state)' has an invalid frame count." -path "rows/$($row.state)"
                    continue
                }

                $requestedStates[[string]$row.state] = [int]$row.frames
                $expectedFrameCount += [int]$row.frames
            }
        } else {
            Add-StatusItem -target ([ref]$status.issues) -type 'pet_request_rows_missing' -message 'pet_request.json has no rows definition.'
        }

        $expectedStateCount = $requestedStates.Count
        $status.checks.run_layout = @($requestedStates.GetEnumerator() | ForEach-Object { $_.Name })

        if ($petRequest.PSObject.Properties.Name -contains 'canonical_identity_reference') {
            $canonical = $petRequest.canonical_identity_reference.path
            if (-not [string]::IsNullOrWhiteSpace($canonical)) {
                $canonicalPath = Join-Path $runPath $canonical
                $status.checks.assets['canonical_identity_ref'] = Test-Path $canonicalPath
                if ($canonical -match '^[A-Za-z]:\\') {
                    Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'path_not_portable' -message "canonical_identity_reference.path is absolute; prefer run-relative path." -path $canonical
                }
            } else {
                $status.checks.assets['canonical_identity_ref'] = $false
                Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'canonical_missing_path' -message 'canonical_identity_reference exists but path is empty.'
            }
        } else {
            $status.checks.assets['canonical_identity_ref'] = $false
            Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'canonical_missing' -message 'canonical_identity_reference missing from pet_request.json.'
        }

        if ($petRequest.PSObject.Properties.Name -contains 'references') {
            $referenceIndex = -1
            foreach ($ref in $petRequest.references) {
                $referenceIndex++
                if ($null -ne $ref.path -and $ref.path -match '^[A-Za-z]:\\') {
                    Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'path_not_portable' -message "references[$referenceIndex].path is absolute; prefer run-relative path." -path $ref.path
                }
                if ($null -ne $ref.source_path -and $ref.source_path -match '^[A-Za-z]:\\') {
                    Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'path_not_portable' -message "references[$referenceIndex].source_path is absolute; prefer run-relative path." -path $ref.source_path
                }
            }
        } else {
            Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'references_missing' -message 'pet_request.json has no references section.'
        }

    } catch {
        Add-StatusItem -target ([ref]$status.issues) -type 'pet_request_invalid' -message "pet_request.json cannot be parsed as JSON. $($_.Exception.Message)" -path 'pet_request.json'
    }
} else {
    Add-StatusItem -target ([ref]$status.issues) -type 'pet_request_missing' -message 'Missing pet_request.json' -path 'pet_request.json'
    $status.checks.assets['canonical_identity_ref'] = $false
}

if ($status.checks.directories['frames']) {
    $frameDirs = @(Get-ChildItem -Path (Join-Path $runPath 'frames') -Directory | Select-Object -ExpandProperty Name)
    $status.checks.required_frame_dirs = @($frameDirs)
    $knownStates = @($requestedStates.Keys)

    foreach ($state in $frameDirs) {
        if ($knownStates -notcontains $state) {
            Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'frames_unknown_state' -message "Unexpected frame state directory '$state' not declared in pet_request rows."
        }
    }

    foreach ($state in $requestedStates.Keys | Sort-Object) {
        $expectedFrames = $requestedStates[$state]
        $stateDir = Join-Path (Join-Path $runPath 'frames') $state
        $actualFiles = @()
        if (Test-Path $stateDir) {
            $actualFiles = @(Get-ChildItem -Path $stateDir -Filter '*.png' -File | Sort-Object Name)
        }
        $actualFrameCount += $actualFiles.Count

        $stateStatus = if ($actualFiles.Count -eq $expectedFrames) {
            'ok'
        } elseif ($actualFiles.Count -eq 0) {
            'missing'
        } else {
            'partial'
        }

        $status.checks.frames += [ordered]@{
            state = $state
            expected_frames = $expectedFrames
            actual_frames = $actualFiles.Count
            state_dir_exists = (Test-Path $stateDir)
            sample_files = @(
                $actualFiles | Select-Object -First 3 | ForEach-Object { $_.Name }
            )
            status = $stateStatus
        }

        if ($expectedFrames -gt 0 -and $actualFiles.Count -lt $expectedFrames) {
            if ($actualFiles.Count -eq 0) {
                Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'frames_missing_state' -message "State '$state' missing all frames. Need $expectedFrames PNG files." -path "frames/$state"
            } else {
                Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'frames_partial_state' -message "State '$state' incomplete: $($actualFiles.Count)/$expectedFrames frames." -path "frames/$state"
            }
        }
    }
}
else {
    Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'frames_dir_missing' -message "frames directory not found." -path 'frames'
}

$jobsPath = Join-Path $runPath 'imagegen-jobs.json'
if ($status.checks.assets['imagegen-jobs.json']) {
    try {
        $jobsRoot = Get-Content $jobsPath -Raw | ConvertFrom-Json
        if ($jobsRoot.PSObject.Properties.Name -contains 'jobs' -and $null -ne $jobsRoot.jobs) {
            $jobs = @($jobsRoot.jobs)
            $status.jobs.total = $jobs.Count
            $status.jobs.complete = @($jobs | Where-Object { $_.status -eq 'complete' }).Count
            $status.jobs.pending = @($jobs | Where-Object { $_.status -eq 'pending' }).Count
            $status.jobs.failed = @($jobs | Where-Object { $_.status -eq 'failed' }).Count
            $status.jobs.paused = @($jobs | Where-Object { $_.status -eq 'paused' }).Count
            $validStatuses = @('complete', 'failed', 'pending', 'paused', 'running')
            $invalidJobs = @($jobs | Where-Object { $null -ne $_.status -and $validStatuses -notcontains $_.status })
            if ($invalidJobs.Count -gt 0) {
                Add-StatusItem -target ([ref]$status.warnings) -kind warning -type 'jobs_unknown_status' -message "Found $($invalidJobs.Count) jobs with unknown status values."
            }
        } else {
            $status.issues += [ordered]@{ type = 'jobs_missing_jobs_array'; message = 'imagegen-jobs.json exists but does not contain a jobs array.'; path = 'imagegen-jobs.json' }
        }
    } catch {
        Add-StatusItem -target ([ref]$status.issues) -type 'jobs_invalid' -message "imagegen-jobs.json cannot be parsed as JSON. $($_.Exception.Message)" -path 'imagegen-jobs.json'
    }
} else {
    Add-StatusItem -target ([ref]$status.issues) -type 'jobs_missing' -message 'Missing imagegen-jobs.json'
}

    $status.summary = [ordered]@{
        all_directories_exist = (-not ($status.checks.directories.Values | Where-Object { -not $_ }))
        canonical_reference_available = [bool]$status.checks.assets['canonical_identity_ref']
        frame_states_complete = -not ($status.checks.frames | Where-Object { $_.status -ne 'ok' })
        no_missing_assets = ($status.issues.Count -eq 0)
        expected_frames = $expectedFrameCount
        actual_frames = $actualFrameCount
        expected_states = $expectedStateCount
    }

$frameRatio = if ($summaryExpected = $status.summary.expected_frames) { [double]$status.summary.actual_frames / [double]$summaryExpected } else { 1.0 }
$jobRatio = if ($status.jobs.total -gt 0) { [double]$status.jobs.complete / [double]$status.jobs.total } else { 1.0 }
$status.summary.frame_completion_ratio = [Math]::Round(($frameRatio * 100), 1)
$status.summary.jobs_completion_ratio = [Math]::Round(($jobRatio * 100), 1)
$status.summary.readiness_score = [int][Math]::Round(((0.6 * $frameRatio) + (0.4 * $jobRatio)) * 100)

if ($status.issues.Count -eq 0) {
    if ($status.warnings.Count -eq 0) {
        $status.state = 'healthy'
        $status.gate.ready_for_generation = $true
    } else {
        $status.state = 'degraded'
        $status.gate.ready_for_generation = $false
        $status.gate.reasons += 'Has warnings; pipeline is usable only after checks are reviewed.'
    }
} else {
    $status.state = 'blocked'
    $status.gate.ready_for_generation = $false
    $status.gate.reasons += 'Has blocking issues.'
}

if ($status.state -eq 'healthy') {
    $status.checks.extras += New-ArtifactReport -name 'status' -path (Join-Path (Join-Path $runPath 'qa') 'run-status.json') -exists $true -count 1
}
else {
    $status.checks.extras += New-ArtifactReport -name 'status' -path (Join-Path (Join-Path $runPath 'qa') 'run-status.json') -exists (Test-Path (Join-Path (Join-Path $runPath 'qa') 'run-status.json')) -count 1
}

if (-not $NoWrite) {
    $qaDir = Join-Path $runPath 'qa'
    if (-not (Test-Path $qaDir)) {
        New-Item -ItemType Directory -Path $qaDir -Force | Out-Null
    }
    $out = Join-Path $qaDir 'run-status.json'
    $status | ConvertTo-Json -Depth 8 | Set-Content -Path $out -Encoding utf8
}

[pscustomobject]$status
