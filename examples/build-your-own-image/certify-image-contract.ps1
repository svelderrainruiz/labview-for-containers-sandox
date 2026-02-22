[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ContractProfile,
    [Parameter(Mandatory = $true)][string]$ImageTag,
    [string]$RunnerTarget = 'hosted-2022',
    [ValidateSet('process', 'hyperv')][string]$IsolationMode = 'process',
    [ValidateRange(1, 10)][int]$MaxCliAttempts = 2,
    [string]$LogRoot = 'TestResults/agent-logs',
    [int]$RepeatRuns = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-RunnerFingerprint {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $caption = if ($null -ne $os) { [string]$os.Caption } else { '' }
    $version = if ($null -ne $os) { [string]$os.Version } else { '' }
    $build = if ($null -ne $os) { [string]$os.BuildNumber } else { '' }
    $isRealServer2019 = ($caption -match 'Server') -and ($build -eq '17763')

    $dockerServerOs = 'unknown'
    try {
        $dockerServerOs = (& docker version --format '{{.Server.Os}}' 2>$null).Trim()
        if ([string]::IsNullOrWhiteSpace($dockerServerOs)) {
            $dockerServerOs = 'unknown'
        }
    }
    catch {
        $dockerServerOs = 'unavailable'
    }

    return [ordered]@{
        os_caption = $caption
        os_version = $version
        os_build = $build
        docker_server_os = $dockerServerOs
        is_real_server2019 = $isRealServer2019
    }
}

function Get-RunSummaryPath {
    param([Parameter(Mandatory = $true)][string]$RunRoot)

    $summary = Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Filter 'summary.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $summary) {
        return $null
    }

    return $summary.FullName
}

$repoRoot = Get-RepoRoot
$profilePath = Join-Path $repoRoot 'Tooling\image-contract-profiles.json'
$schemaPath = Join-Path $repoRoot 'Tooling\image-cert-summary.schema.json'
$verifierScriptPath = Join-Path $PSScriptRoot 'verify-lv-cli-masscompile-from-image.ps1'
$statusRoot = Join-Path $repoRoot 'builds\status'

Ensure-Directory -Path $statusRoot
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw "Image contract profile file not found: $profilePath"
}
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Image certification schema file not found: $schemaPath"
}
if (-not (Test-Path -LiteralPath $verifierScriptPath -PathType Leaf)) {
    throw "Verifier script not found: $verifierScriptPath"
}

$profiles = Get-Content -LiteralPath $profilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
if (-not $profiles.PSObject.Properties.Name.Contains('profiles')) {
    throw "Invalid profile file: missing 'profiles' object at $profilePath"
}
if (-not $profiles.profiles.PSObject.Properties.Name.Contains($ContractProfile)) {
    $availableProfiles = @($profiles.profiles.PSObject.Properties.Name) -join ', '
    throw "Unknown ContractProfile '$ContractProfile'. Available profiles: $availableProfiles"
}

$profile = $profiles.profiles.$ContractProfile
$lvYear = [string]$profile.lv_year
$lvCliPort = [string]$profile.lv_cli_port
$directoryToCompile = [string]$profile.directory_to_compile
$requiresRealServer2019 = [bool]$profile.requires_real_server2019
$requirePortListener = $true
if ($profile.PSObject.Properties.Name.Contains('require_port_listener')) {
    $requirePortListener = [bool]$profile.require_port_listener
}
$profileRepeatRuns = [int]$profile.required_repeat_runs
$effectiveRepeatRuns = if ($RepeatRuns -gt 0) { [int]$RepeatRuns } else { [int]$profileRepeatRuns }
if ($effectiveRepeatRuns -lt 1) {
    $effectiveRepeatRuns = 1
}

$resolvedLogRoot = if ([System.IO.Path]::IsPathRooted($LogRoot)) { $LogRoot } else { Join-Path $repoRoot $LogRoot }
Ensure-Directory -Path $resolvedLogRoot

$runStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
$certRunRoot = Join-Path $resolvedLogRoot ("certification-{0}" -f $runStamp)
Ensure-Directory -Path $certRunRoot

$fingerprint = Get-RunnerFingerprint
$reasons = New-Object System.Collections.Generic.List[string]
$sourceLogPaths = New-Object System.Collections.Generic.List[string]
$runResults = New-Object System.Collections.Generic.List[object]
$passCount = 0
$failureCount = 0

if ($requiresRealServer2019 -and -not $fingerprint.is_real_server2019) {
    $reasons.Add('Profile requires real Server 2019 lane; current runner fingerprint does not satisfy this requirement.') | Out-Null
}

for ($index = 1; $index -le $effectiveRepeatRuns; $index++) {
    $runLogRoot = Join-Path $certRunRoot ("run-{0:00}" -f $index)
    Ensure-Directory -Path $runLogRoot
    $sourceLogPaths.Add($runLogRoot) | Out-Null

    $runError = ''
    $runSummaryPath = $null
    $runSummary = $null
    $runPass = $false
    $runFinalExit = $null
    $runContains350000 = $null
    $runPortListening = $null

    try {
        & $verifierScriptPath `
            -ImageTag $ImageTag `
            -LvYear $lvYear `
            -LvCliPort $lvCliPort `
            -DirectoryToCompile $directoryToCompile `
            -IsolationMode $IsolationMode `
            -MaxCliAttempts $MaxCliAttempts `
            -LogRoot $runLogRoot
    }
    catch {
        $runError = $_.Exception.Message
    }

    $runSummaryPath = Get-RunSummaryPath -RunRoot $runLogRoot
    if (-not [string]::IsNullOrWhiteSpace($runSummaryPath) -and (Test-Path -LiteralPath $runSummaryPath -PathType Leaf)) {
        $sourceLogPaths.Add($runSummaryPath) | Out-Null
        try {
            $runSummary = Get-Content -LiteralPath $runSummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $runFinalExit = if ($null -ne $runSummary.final_exit_code) { [int]$runSummary.final_exit_code } else { $null }
            $runContains350000 = [bool]$runSummary.contains_minus_350000
            $runPortListening = [bool]$runSummary.port_listening_before_cli
            $listenerGateSatisfied = if ($requirePortListener) { $runPortListening } else { $true }
            $runPass = [bool]$runSummary.run_succeeded -and ($runFinalExit -eq 0) -and (-not $runContains350000) -and $listenerGateSatisfied
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($runError)) {
                $runError = "Unable to parse verifier summary at ${runSummaryPath}: $($_.Exception.Message)"
            }
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($runError)) {
        $runError = 'Verifier summary.json was not found.'
    }

    if ($runPass) {
        $passCount += 1
    }
    else {
        $failureCount += 1
    }

    $runResults.Add([pscustomobject]@{
        run_index = $index
        pass = $runPass
        summary_path = $runSummaryPath
        final_exit_code = $runFinalExit
        contains_minus_350000 = $runContains350000
        port_listening_before_cli = $runPortListening
        error = $runError
        logs_path = $runLogRoot
    }) | Out-Null
}

$anyMinus350000 = $false
$allPortListening = $true
$hasPreflightOrExecutionError = $false
$hasMissingImageError = $false
$firstRunError = ''
foreach ($result in $runResults) {
    if ($result.contains_minus_350000 -eq $true) {
        $anyMinus350000 = $true
    }
    if ($result.port_listening_before_cli -ne $true) {
        $allPortListening = $false
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$result.error)) {
        $hasPreflightOrExecutionError = $true
        if ([string]::IsNullOrWhiteSpace($firstRunError)) {
            $firstRunError = [string]$result.error
        }
        if ([string]$result.error -match '(?i)image not found locally|no such image|manifest unknown|pull access denied') {
            $hasMissingImageError = $true
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$result.summary_path)) {
        $hasPreflightOrExecutionError = $true
    }
}

$classification = 'verifier_execution_error'
if ($requiresRealServer2019 -and -not $fingerprint.is_real_server2019) {
    $classification = 'environment_incompatible'
}
elseif ($failureCount -eq 0 -and $passCount -eq $effectiveRepeatRuns) {
    $classification = 'pass'
}
elseif ($hasMissingImageError -or $hasPreflightOrExecutionError) {
    $classification = 'verifier_execution_error'
}
elseif ($anyMinus350000 -or @($runResults | Where-Object { $_.final_exit_code -ne $null -and $_.final_exit_code -ne 0 }).Count -gt 0) {
    $classification = 'cli_connect_fail'
}
elseif ($requirePortListener -and -not $allPortListening) {
    $classification = 'port_not_listening'
}

if ($classification -eq 'pass') {
    $reasons.Add("All $effectiveRepeatRuns run(s) passed with listening port and no -350000.") | Out-Null
}
elseif ($classification -eq 'port_not_listening') {
    $reasons.Add('At least one run reported port_listening_before_cli=false.') | Out-Null
}
elseif ($classification -eq 'cli_connect_fail') {
    $reasons.Add('At least one run had -350000 or a non-zero final_exit_code.') | Out-Null
}

if ($classification -eq 'pass' -and -not $requirePortListener -and -not $allPortListening) {
    $reasons.Add('Port listener was not enforced for this profile; pass was determined by CLI outcome metrics.') | Out-Null
}
elseif ($classification -eq 'verifier_execution_error') {
    if ($hasMissingImageError) {
        $reasons.Add("Image acquisition/preflight failed (missing image). First error: $firstRunError") | Out-Null
    }
    else {
        $reasons.Add('Verifier execution failed before producing a passing summary set.') | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($firstRunError)) {
            $reasons.Add("First run error: $firstRunError") | Out-Null
        }
    }
}

$promotionEligible = ($classification -eq 'pass') -and ($passCount -eq $effectiveRepeatRuns)
if ($requiresRealServer2019 -and -not $fingerprint.is_real_server2019) {
    $promotionEligible = $false
}

$safeProfile = ($ContractProfile -replace '[^A-Za-z0-9_.-]', '-')
$summaryTimestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
$certSummaryPath = Join-Path $statusRoot ("image-contract-cert-summary-{0}-{1}.json" -f $safeProfile, $summaryTimestamp)

$summary = [ordered]@{
    schema_version = '1.0'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    contract_profile = $ContractProfile
    image_tag = $ImageTag
    runner_target = $RunnerTarget
    runner_fingerprint = $fingerprint
    verification_metrics = [ordered]@{
        repeat_runs_requested = $effectiveRepeatRuns
        runs_completed = $runResults.Count
        pass_count = $passCount
        failure_count = $failureCount
        all_runs_port_listening = $allPortListening
        any_minus_350000 = $anyMinus350000
        has_preflight_or_execution_error = $hasPreflightOrExecutionError
        has_missing_image_error = $hasMissingImageError
        run_results = $runResults
    }
    classification = $classification
    promotion_eligible = $promotionEligible
    reasons = @($reasons)
    source_log_paths = @($sourceLogPaths | Select-Object -Unique)
    schema_path = $schemaPath
    profile_path = $profilePath
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -Path $certSummaryPath -Encoding utf8
Write-Host "cert_summary_path=$certSummaryPath"
Write-Host "cert_classification=$classification"
Write-Host "promotion_eligible=$promotionEligible"

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("cert_summary_path={0}" -f $certSummaryPath)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("cert_classification={0}" -f $classification)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("promotion_eligible={0}" -f $promotionEligible.ToString().ToLowerInvariant())
}

if ($classification -ne 'pass') {
    throw "Image contract certification failed with classification '$classification'. See $certSummaryPath"
}
