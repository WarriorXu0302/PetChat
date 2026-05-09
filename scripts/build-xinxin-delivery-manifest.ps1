param(
    [string]$RunDir = '.\\xinxin-run',

    [string]$OutputFile = $null,

    [switch]$RequireHealthy,

    [switch]$NoWrite,

    [switch]$UpdateLegacySummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runRoot = Resolve-Path $RunDir
$scriptDir = Split-Path -Parent $PSCommandPath
$collectScript = Join-Path $scriptDir 'collect-pet-run-status.ps1'

function New-ArtifactInfo {
    param(
        [string]$Name,
        [string]$Path,
        [bool]$Required = $false
    )

    $exists = Test-Path $Path
    $entry = [ordered]@{
        name = $Name
        path = $Path
        required = $Required
        exists = $exists
    }

    if ($exists) {
        $file = Get-Item $Path
        $entry.size_bytes = $file.Length
        $entry.sha256 = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
        $entry.last_write_time_utc = $file.LastWriteTimeUtc.ToString('o')
        $entry.extension = $file.Extension
    }

    return $entry
}

$status = & $collectScript -RunDir $runRoot

if ($RequireHealthy -and $status.state -ne 'healthy') {
    throw "Release manifest requires healthy state, but run is '$($status.state)'."
}

$qaDir = Join-Path $runRoot 'qa'
if (-not (Test-Path $qaDir)) {
    New-Item -ItemType Directory -Path $qaDir -Force | Out-Null
}

$petRequest = $null
$petRequestPath = Join-Path $runRoot 'pet_request.json'
if (Test-Path $petRequestPath) {
    try {
        $petRequest = Get-Content $petRequestPath -Raw | ConvertFrom-Json
    } catch {
        $petRequest = $null
    }
}

$expectedStateNames = @()
if ($null -ne $petRequest -and ($petRequest.PSObject.Properties.Name -contains 'rows') -and $petRequest.rows) {
    $expectedStateNames = @($petRequest.rows | ForEach-Object { $_.state })
}

$finalDir = Join-Path $runRoot 'final'
$qaFiles = @(
    (Join-Path $qaDir 'contact-sheet.png'),
    (Join-Path $qaDir 'review.json'),
    (Join-Path $qaDir 'run-status.json')
)

$finalArtifacts = @(
    (Join-Path $finalDir 'spritesheet.png'),
    (Join-Path $finalDir 'spritesheet.webp'),
    (Join-Path $finalDir 'validation.json')
)
foreach ($state in $expectedStateNames) {
    $finalArtifacts += Join-Path $finalDir "$state.png"
}
if (Test-Path (Join-Path $finalDir 'base.png')) {
    $finalArtifacts += Join-Path $finalDir 'base.png'
}

$delivery = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    run_dir = $runRoot.Path
    pet_id = $status.pet_id
    state = $status.state
    gate = $status.gate
    status = @{
        issues = $status.issues
        warnings = $status.warnings
        summary = $status.summary
        jobs = $status.jobs
    }
    artifacts = @()
    checks = @{
        total_files = 0
        present_files = 0
        missing_required_files = 0
    }
}

$requiredCount = 0
$presentRequiredCount = 0
foreach ($file in $finalArtifacts) {
    $required = $true
    $requiredCount++
    $artifact = New-ArtifactInfo -Name (Split-Path $file -Leaf) -Path $file -Required $required
    if ($artifact.exists) { $presentRequiredCount++ }
    $delivery.artifacts += $artifact
    $delivery.checks.total_files++
    if ($artifact.exists) { $delivery.checks.present_files++ } else { $delivery.checks.missing_required_files++ }
}

foreach ($file in $qaFiles) {
    $delivery.artifacts += New-ArtifactInfo -Name (Split-Path $file -Leaf) -Path $file -Required $false
    $delivery.checks.total_files++
    if (Test-Path $file) {
        $delivery.checks.present_files++
    }
}

$delivery.checks.required_files = $requiredCount
$delivery.checks.present_required_files = $presentRequiredCount
$delivery.checks.package_readiness = if ($requiredCount -gt 0) {
    [Math]::Round(($presentRequiredCount / $requiredCount) * 100, 1)
} else {
    0
}

if ($null -ne $petRequest -and ($petRequest.PSObject.Properties.Name -contains 'layout_guides')) {
    $delivery.layout_guides = @($petRequest.layout_guides | ForEach-Object {
        @{
            state = $_.state
            path = $_.path
            frames = $_.frames
        }
    })
}

if ($OutputFile) {
    $destination = $OutputFile
} else {
    $destination = Join-Path $qaDir 'delivery-manifest.json'
}

if (-not $NoWrite) {
    $delivery | ConvertTo-Json -Depth 10 | Set-Content -Path $destination -Encoding utf8
}

if (-not $NoWrite -and $UpdateLegacySummary) {
    $legacySummary = [ordered]@{
        ok = ($status.state -eq 'healthy')
        run_dir = $runRoot.Path
        spritesheet = Join-Path $finalDir 'spritesheet.webp'
        validation = Join-Path $finalDir 'validation.json'
        contact_sheet = Join-Path $qaDir 'contact-sheet.png'
        review = Join-Path $qaDir 'review.json'
        videos = Join-Path $runRoot 'videos'
        package = Join-Path (Split-Path $runRoot) 'package'
    }
    $legacyOut = Join-Path $qaDir 'run-summary.json'
    $legacySummary | ConvertTo-Json -Depth 10 | Set-Content -Path $legacyOut -Encoding utf8
}

$delivery
