[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SummaryPath,
    [string]$ExpectedContractProfile = '',
    [string]$ExpectedImageTag = '',
    [int]$MinRepeatRuns = 1,
    [switch]$RequireLocalSourceLogPaths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HasProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Object.PSObject.Properties.Name.Contains($Name)) {
        throw "Missing required property '$Name'."
    }
}

function Assert-StringNotBlank {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Property '$Name' must be a non-empty string."
    }
}

if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    throw 'SummaryPath is empty. Certification did not produce a summary file path.'
}

if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) {
    throw "Summary file not found: $SummaryPath"
}

$summary = Get-Content -LiteralPath $SummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

$requiredTop = @(
    'schema_version',
    'generated_utc',
    'contract_profile',
    'image_tag',
    'runner_fingerprint',
    'verification_metrics',
    'classification',
    'promotion_eligible',
    'reasons',
    'source_log_paths'
)
foreach ($name in $requiredTop) {
    Assert-HasProperty -Object $summary -Name $name
}

Assert-StringNotBlank -Value ([string]$summary.schema_version) -Name 'schema_version'
Assert-StringNotBlank -Value ([string]$summary.generated_utc) -Name 'generated_utc'
Assert-StringNotBlank -Value ([string]$summary.contract_profile) -Name 'contract_profile'
Assert-StringNotBlank -Value ([string]$summary.image_tag) -Name 'image_tag'
Assert-StringNotBlank -Value ([string]$summary.classification) -Name 'classification'

if (-not [string]::IsNullOrWhiteSpace($ExpectedContractProfile) -and [string]$summary.contract_profile -ne $ExpectedContractProfile) {
    throw "contract_profile mismatch. expected='$ExpectedContractProfile' actual='$($summary.contract_profile)'"
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedImageTag) -and [string]$summary.image_tag -ne $ExpectedImageTag) {
    throw "image_tag mismatch. expected='$ExpectedImageTag' actual='$($summary.image_tag)'"
}

$allowedClassifications = @(
    'pass',
    'port_not_listening',
    'cli_connect_fail',
    'environment_incompatible',
    'verifier_execution_error'
)
if ($allowedClassifications -notcontains [string]$summary.classification) {
    throw "classification '$($summary.classification)' is not in allowed set: $($allowedClassifications -join ', ')"
}

$metrics = $summary.verification_metrics
$requiredMetrics = @(
    'repeat_runs_requested',
    'runs_completed',
    'pass_count',
    'failure_count',
    'all_runs_port_listening',
    'any_minus_350000',
    'has_preflight_or_execution_error',
    'has_missing_image_error',
    'run_results'
)
foreach ($name in $requiredMetrics) {
    Assert-HasProperty -Object $metrics -Name $name
}

$effectiveMinRepeatRuns = if ($MinRepeatRuns -gt 0) { $MinRepeatRuns } else { 1 }
$repeatRunsRequested = [int]$metrics.repeat_runs_requested
$runsCompleted = [int]$metrics.runs_completed
$passCount = [int]$metrics.pass_count
$failureCount = [int]$metrics.failure_count
$runResults = @($metrics.run_results)

if ($repeatRunsRequested -lt $effectiveMinRepeatRuns) {
    throw "repeat_runs_requested ($repeatRunsRequested) is below required minimum ($effectiveMinRepeatRuns)."
}
if ($runsCompleted -lt 1) {
    throw "runs_completed must be >= 1. Actual: $runsCompleted"
}
if ($runsCompleted -ne $runResults.Count) {
    throw "runs_completed ($runsCompleted) must match run_results count ($($runResults.Count))."
}
if (($passCount + $failureCount) -ne $runsCompleted) {
    throw "pass_count + failure_count must equal runs_completed. pass_count=$passCount failure_count=$failureCount runs_completed=$runsCompleted"
}

if ($summary.reasons -isnot [System.Collections.IEnumerable] -or @($summary.reasons).Count -lt 1) {
    throw 'reasons must contain at least one entry.'
}
if ($summary.source_log_paths -isnot [System.Collections.IEnumerable] -or @($summary.source_log_paths).Count -lt 1) {
    throw 'source_log_paths must contain at least one entry.'
}

$missingSourcePaths = New-Object System.Collections.Generic.List[string]
if ($RequireLocalSourceLogPaths) {
    foreach ($path in @($summary.source_log_paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) {
            continue
        }
        if (-not (Test-Path -LiteralPath ([string]$path))) {
            $missingSourcePaths.Add([string]$path) | Out-Null
        }
    }
}

$requiredRunResultProperties = @(
    'run_index',
    'pass',
    'summary_path',
    'final_exit_code',
    'contains_minus_350000',
    'port_listening_before_cli',
    'error',
    'logs_path'
)
foreach ($runResult in $runResults) {
    foreach ($propertyName in $requiredRunResultProperties) {
        Assert-HasProperty -Object $runResult -Name $propertyName
    }
}

if ([string]$summary.classification -eq 'pass') {
    if ($passCount -ne $runsCompleted) {
        throw "classification=pass requires pass_count == runs_completed. pass_count=$passCount runs_completed=$runsCompleted"
    }
    if (-not [bool]$summary.promotion_eligible) {
        throw 'classification=pass requires promotion_eligible=true.'
    }
}

if ($missingSourcePaths.Count -gt 0) {
    throw "Missing local source_log_paths detected: $($missingSourcePaths -join '; ')"
}

Write-Host "Certification evidence contract verified: $SummaryPath"
Write-Host "classification=$($summary.classification); runs_completed=$runsCompleted; pass_count=$passCount; failure_count=$failureCount"
