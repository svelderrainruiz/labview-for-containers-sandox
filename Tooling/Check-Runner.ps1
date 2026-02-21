#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$HostContractPath = 'Tooling/runner-host-contract.json',
    [switch]$EnforceHostContract,
    [string[]]$RequiredLabVIEWYears,
    [Nullable[int]]$RequiredCliMajor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvValue {
    param([string]$Name)

    if (Test-Path "Env:$Name") {
        return (Get-Item "Env:$Name").Value
    }

    return $null
}

function Test-EnvBool {
    param(
        [string]$Name,
        [bool]$Default = $false
    )

    $value = Get-EnvValue -Name $Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    return ($value.Trim().ToLowerInvariant() -notin @('0', 'false', 'no'))
}

function Convert-ToStringArray {
    param([object]$Value)

    $items = @()
    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($entry in $Value) {
            if ($null -ne $entry) {
                $items += [string]$entry
            }
        }
    } else {
        $items += [string]$Value
    }

    $normalized = @()
    foreach ($item in $items) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        foreach ($segment in ($item -split '[,;]')) {
            $trimmed = $segment.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $normalized += $trimmed
            }
        }
    }

    return @($normalized)
}

function Resolve-RepoRootPath {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (Test-Path -LiteralPath $Path) {
            return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        }

        throw "RepoRoot does not exist: $Path"
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE) -and (Test-Path -LiteralPath $env:GITHUB_WORKSPACE)) {
        return (Resolve-Path -LiteralPath $env:GITHUB_WORKSPACE -ErrorAction Stop).Path
    }

    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
    return (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path
}

function Resolve-RepoRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Get-LabVIEWInstallRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][ValidateSet('32', '64')][string]$Bitness
    )

    $candidates = @()
    $regPaths = @()

    if ($Bitness -eq '32') {
        $candidates += "C:\Program Files (x86)\National Instruments\LabVIEW $Version"
        $regPaths += "HKLM:\SOFTWARE\WOW6432Node\National Instruments\LabVIEW $Version"
    } else {
        $candidates += "C:\Program Files\National Instruments\LabVIEW $Version"
        $regPaths += "HKLM:\SOFTWARE\National Instruments\LabVIEW $Version"
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    foreach ($regPath in $regPaths) {
        try {
            $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
            foreach ($name in @('Path', 'InstallDir', 'InstallPath')) {
                $value = $props.$name
                if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value)) {
                    return $value
                }
            }
        } catch {
            continue
        }
    }

    return $null
}

function Get-IniValueStrict {
    param(
        [Parameter(Mandatory = $true)][string]$IniPath,
        [Parameter(Mandatory = $true)][string]$Key
    )

    foreach ($line in Get-Content -LiteralPath $IniPath -ErrorAction Stop) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $trimmed = $line.Trim()
        if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            continue
        }

        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }

        $lineKey = $trimmed.Substring(0, $separator).Trim()
        if ($lineKey.Equals($Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $trimmed.Substring($separator + 1).Trim()
        }
    }

    return $null
}

function Set-IniValueStrict {
    param(
        [Parameter(Mandatory = $true)][string]$IniPath,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $lines = @(Get-Content -LiteralPath $IniPath -ErrorAction Stop)
    $updated = $false

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            continue
        }

        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }

        $lineKey = $trimmed.Substring(0, $separator).Trim()
        if ($lineKey.Equals($Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            $lines[$index] = ('{0}={1}' -f $Key, $Value)
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        $lines += ('{0}={1}' -f $Key, $Value)
    }

    Set-Content -LiteralPath $IniPath -Value $lines -Encoding ascii
}

function Resolve-FileMajorVersion {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $major = $item.VersionInfo.FileMajorPart
    if ($major -is [int] -and $major -gt 0) {
        return $major
    }

    $productVersion = [string]$item.VersionInfo.ProductVersion
    if (-not [string]::IsNullOrWhiteSpace($productVersion) -and $productVersion -match '^\D*(?<major>\d+)') {
        return [int]$Matches['major']
    }

    return $null
}

$resolvedRepoRoot = Resolve-RepoRootPath -Path $RepoRoot
$enforceHostContract = $EnforceHostContract.IsPresent -or (Test-EnvBool -Name 'LVIE_ENFORCE_DEDICATED_HOST_CONTRACT' -Default $false)

Write-Host ("Runner check: repo_root={0}" -f $resolvedRepoRoot)
Write-Host ("Runner check: enforce_host_contract={0}" -f $enforceHostContract)

if (-not $enforceHostContract) {
    Write-Host 'Dedicated host contract enforcement is disabled. Nothing to validate.'
    return
}

if (-not $IsWindows) {
    throw 'Dedicated host contract enforcement is supported only on Windows runners.'
}

$resolvedHostContractPath = Resolve-RepoRelativePath -RepoRoot $resolvedRepoRoot -Path $HostContractPath
if (-not (Test-Path -LiteralPath $resolvedHostContractPath -PathType Leaf)) {
    throw "Host contract file not found: $resolvedHostContractPath"
}

$hostContract = Get-Content -LiteralPath $resolvedHostContractPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$requiredBitness = @(Convert-ToStringArray -Value $hostContract.required_bitness)
if ($requiredBitness.Count -eq 0) {
    $requiredBitness = @('64', '32')
}

$requiredYears = @()
if ($PSBoundParameters.ContainsKey('RequiredLabVIEWYears')) {
    $requiredYears = @(Convert-ToStringArray -Value $RequiredLabVIEWYears)
}
if ($requiredYears.Count -eq 0) {
    $requiredYears = @(Convert-ToStringArray -Value (Get-EnvValue -Name 'LVIE_REQUIRED_LABVIEW_YEARS'))
}
if ($requiredYears.Count -eq 0) {
    $requiredYears = @(Convert-ToStringArray -Value $hostContract.required_labview_years)
}
if ($requiredYears.Count -eq 0) {
    throw 'No required LabVIEW years were resolved from parameters, env, or host contract.'
}

$requiredCliMajorValue = $null
if ($PSBoundParameters.ContainsKey('RequiredCliMajor') -and $null -ne $RequiredCliMajor) {
    $requiredCliMajorValue = [int]$RequiredCliMajor
}
if ($null -eq $requiredCliMajorValue) {
    $requiredCliMajorRaw = Get-EnvValue -Name 'LVIE_REQUIRED_CLI_MAJOR'
    if (-not [string]::IsNullOrWhiteSpace($requiredCliMajorRaw)) {
        $parsedCliMajor = 0
        if (-not [int]::TryParse($requiredCliMajorRaw.Trim(), [ref]$parsedCliMajor)) {
            throw "LVIE_REQUIRED_CLI_MAJOR is invalid: '$requiredCliMajorRaw'"
        }
        $requiredCliMajorValue = $parsedCliMajor
    }
}
if ($null -eq $requiredCliMajorValue) {
    $requiredCliMajorValue = [int]$hostContract.required_cli_major
}

$portContractRelativePath = if ([string]::IsNullOrWhiteSpace([string]$hostContract.port_contract_path)) {
    'Tooling/labviewcli-port-contract.json'
} else {
    [string]$hostContract.port_contract_path
}
$resolvedPortContractPath = Resolve-RepoRelativePath -RepoRoot $resolvedRepoRoot -Path $portContractRelativePath
if (-not (Test-Path -LiteralPath $resolvedPortContractPath -PathType Leaf)) {
    throw "Port contract file not found: $resolvedPortContractPath"
}

$portContract = Get-Content -LiteralPath $resolvedPortContractPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
if (-not $portContract.PSObject.Properties.Name.Contains('labview_cli_ports')) {
    throw "Port contract missing 'labview_cli_ports': $resolvedPortContractPath"
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
$statusRoot = Join-Path $resolvedRepoRoot 'builds\status'
if (-not (Test-Path -LiteralPath $statusRoot)) {
    New-Item -Path $statusRoot -ItemType Directory -Force | Out-Null
}
$summaryPath = Join-Path $statusRoot ("check-runner-host-contract-{0}.json" -f $timestamp)

$remediationEnabled = Test-EnvBool -Name 'LVIE_REMEDIATE_LABVIEWCLI_PORT_CONTRACT' -Default $false
$errors = New-Object System.Collections.Generic.List[string]
$matrixChecks = New-Object System.Collections.Generic.List[object]
$iniChecks = New-Object System.Collections.Generic.List[object]

$cliPath = $null
$cliMajor = $null
$cliStatus = 'missing'
$cliCommand = Get-Command -Name 'LabVIEWCLI' -ErrorAction SilentlyContinue
if ($cliCommand) {
    if (-not [string]::IsNullOrWhiteSpace($cliCommand.Source)) {
        $cliPath = $cliCommand.Source
    } elseif (-not [string]::IsNullOrWhiteSpace($cliCommand.Path)) {
        $cliPath = $cliCommand.Path
    }
}
if (-not [string]::IsNullOrWhiteSpace($cliPath) -and (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    $cliMajor = Resolve-FileMajorVersion -Path $cliPath
    if ($null -eq $cliMajor) {
        $cliStatus = 'invalid-version'
        $errors.Add("Unable to resolve LabVIEWCLI version major from $cliPath")
    } elseif ($cliMajor -ne $requiredCliMajorValue) {
        $cliStatus = 'wrong-version'
        $errors.Add(("LabVIEWCLI major mismatch: expected {0}, found {1} at {2}" -f $requiredCliMajorValue, $cliMajor, $cliPath))
    } else {
        $cliStatus = 'pass'
    }
} else {
    $errors.Add('LabVIEWCLI command was not found on PATH.')
}

foreach ($year in $requiredYears) {
    foreach ($bitness in $requiredBitness) {
        $matrixEntry = [ordered]@{
            year = $year
            bitness = $bitness
            install_root = $null
            installed = $false
            status = 'pending'
            error = $null
        }

        $iniEntry = [ordered]@{
            year = $year
            bitness = $bitness
            labview_exe_path = $null
            labview_ini_path = $null
            contract_path = $resolvedPortContractPath
            expected_port = $null
            status = 'pending'
            remediation_enabled = $remediationEnabled
            remediation_applied = $false
            error = $null
        }

        $installRoot = Get-LabVIEWInstallRoot -Version $year -Bitness $bitness
        $matrixEntry.install_root = $installRoot
        if ([string]::IsNullOrWhiteSpace($installRoot)) {
            $matrixEntry.status = 'missing-install'
            $matrixEntry.error = ("LabVIEW {0} ({1}-bit) install root is missing." -f $year, $bitness)
            $iniEntry.status = 'skipped'
            $iniEntry.error = 'install-root-missing'
            $errors.Add($matrixEntry.error)
            $matrixChecks.Add([pscustomobject]$matrixEntry) | Out-Null
            $iniChecks.Add([pscustomobject]$iniEntry) | Out-Null
            continue
        }

        $matrixEntry.installed = $true
        $matrixEntry.status = 'installed'
        $labviewExePath = Join-Path $installRoot 'LabVIEW.exe'
        $labviewIniPath = Join-Path $installRoot 'LabVIEW.ini'
        $iniEntry.labview_exe_path = $labviewExePath
        $iniEntry.labview_ini_path = $labviewIniPath

        if (-not (Test-Path -LiteralPath $labviewExePath -PathType Leaf)) {
            $matrixEntry.status = 'missing-exe'
            $matrixEntry.error = ("LabVIEW executable missing for {0} ({1}-bit): {2}" -f $year, $bitness, $labviewExePath)
            $iniEntry.status = 'missing-exe'
            $iniEntry.error = $matrixEntry.error
            $errors.Add($matrixEntry.error)
            $matrixChecks.Add([pscustomobject]$matrixEntry) | Out-Null
            $iniChecks.Add([pscustomobject]$iniEntry) | Out-Null
            continue
        }

        if (-not (Test-Path -LiteralPath $labviewIniPath -PathType Leaf)) {
            $iniEntry.status = 'missing-ini'
            $iniEntry.error = ("LabVIEW.ini missing for {0} ({1}-bit): {2}" -f $year, $bitness, $labviewIniPath)
            $errors.Add($iniEntry.error)
            $matrixChecks.Add([pscustomobject]$matrixEntry) | Out-Null
            $iniChecks.Add([pscustomobject]$iniEntry) | Out-Null
            continue
        }

        $yearNode = $portContract.labview_cli_ports.PSObject.Properties[$year]
        if ($null -eq $yearNode) {
            $iniEntry.status = 'missing-contract-year'
            $iniEntry.error = ("Port contract missing year '{0}' in {1}" -f $year, $resolvedPortContractPath)
            $errors.Add($iniEntry.error)
            $matrixChecks.Add([pscustomobject]$matrixEntry) | Out-Null
            $iniChecks.Add([pscustomobject]$iniEntry) | Out-Null
            continue
        }

        $bitnessNode = $yearNode.Value.PSObject.Properties[$bitness]
        if ($null -eq $bitnessNode) {
            $iniEntry.status = 'missing-contract-bitness'
            $iniEntry.error = ("Port contract missing bitness '{0}' for year '{1}' in {2}" -f $bitness, $year, $resolvedPortContractPath)
            $errors.Add($iniEntry.error)
            $matrixChecks.Add([pscustomobject]$matrixEntry) | Out-Null
            $iniChecks.Add([pscustomobject]$iniEntry) | Out-Null
            continue
        }

        $expectedPort = 0
        if (-not [int]::TryParse([string]$bitnessNode.Value, [ref]$expectedPort)) {
            $iniEntry.status = 'invalid-contract-port'
            $iniEntry.error = ("Invalid port contract value for year '{0}' bitness '{1}' in {2}" -f $year, $bitness, $resolvedPortContractPath)
            $errors.Add($iniEntry.error)
            $matrixChecks.Add([pscustomobject]$matrixEntry) | Out-Null
            $iniChecks.Add([pscustomobject]$iniEntry) | Out-Null
            continue
        }
        $iniEntry.expected_port = $expectedPort

        $enabledRaw = Get-IniValueStrict -IniPath $labviewIniPath -Key 'server.tcp.enabled'
        $portRaw = Get-IniValueStrict -IniPath $labviewIniPath -Key 'server.tcp.port'
        $remediationApplied = $false

        $enabledOk = -not [string]::IsNullOrWhiteSpace($enabledRaw) -and ($enabledRaw.Trim().ToLowerInvariant() -in @('true', 't', '1', 'yes', 'y'))
        if (-not $enabledOk -and $remediationEnabled) {
            Set-IniValueStrict -IniPath $labviewIniPath -Key 'server.tcp.enabled' -Value 'true'
            $enabledRaw = 'true'
            $enabledOk = $true
            $remediationApplied = $true
        }

        $actualPort = 0
        $portOk = -not [string]::IsNullOrWhiteSpace($portRaw) -and [int]::TryParse($portRaw.Trim(), [ref]$actualPort) -and ($actualPort -eq $expectedPort)
        if (-not $portOk -and $remediationEnabled) {
            Set-IniValueStrict -IniPath $labviewIniPath -Key 'server.tcp.port' -Value $expectedPort.ToString()
            $actualPort = $expectedPort
            $portOk = $true
            $remediationApplied = $true
        }

        $iniEntry.remediation_applied = $remediationApplied
        if ($enabledOk -and $portOk) {
            $iniEntry.status = 'pass'
        } else {
            $iniEntry.status = 'fail'
            $iniEntry.error = ("LabVIEW.ini contract mismatch for year {0} ({1}-bit) at {2}. Expected server.tcp.enabled=true and server.tcp.port={3}." -f $year, $bitness, $labviewIniPath, $expectedPort)
            $errors.Add($iniEntry.error)
        }

        $matrixChecks.Add([pscustomobject]$matrixEntry) | Out-Null
        $iniChecks.Add([pscustomobject]$iniEntry) | Out-Null
    }
}

$summary = [ordered]@{
    schema_version = '1.0'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    repo_root = $resolvedRepoRoot
    status = if ($errors.Count -eq 0) { 'pass' } else { 'failure' }
    host_contract_path = $resolvedHostContractPath
    summary_path = $summaryPath
    contract = [ordered]@{
        cli_policy = [string]$hostContract.cli_policy
        required_bitness = @($requiredBitness)
        required_labview_years = @($requiredYears)
        required_cli_major = $requiredCliMajorValue
        port_contract_path = $resolvedPortContractPath
    }
    overrides = [ordered]@{
        required_labview_years = @(Convert-ToStringArray -Value (Get-EnvValue -Name 'LVIE_REQUIRED_LABVIEW_YEARS'))
        required_cli_major = (Get-EnvValue -Name 'LVIE_REQUIRED_CLI_MAJOR')
    }
    cli = [ordered]@{
        command_path = $cliPath
        required_major = $requiredCliMajorValue
        actual_major = $cliMajor
        status = $cliStatus
    }
    remediation = [ordered]@{
        port_contract_enabled = $remediationEnabled
    }
    matrix_checks = $matrixChecks
    ini_checks = $iniChecks
    errors = @($errors)
}

([pscustomobject]$summary) | ConvertTo-Json -Depth 10 | Out-File -FilePath $summaryPath -Encoding utf8
Write-Host ("Runner host contract summary: {0}" -f $summaryPath)

if ($errors.Count -gt 0) {
    throw ("Dedicated host contract check failed:`n{0}" -f (($errors | ForEach-Object { "- $_" }) -join [Environment]::NewLine))
}

Write-Host 'Dedicated host contract check passed.'
