[CmdletBinding()]
param(
    [string]$LvYear = '2020',
    [string]$LabVIEWPath = '',
    [string]$LvCliPort = '3366',
    [string]$DirectoryToCompile = '',
    [int]$MaxCliAttempts = 2,
    [string]$LogRoot = 'TestResults/agent-logs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-IniKeyValue {
    param(
        [Parameter(Mandatory = $true)][string]$IniPath,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) {
        return $null
    }

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

function Invoke-MassCompileAttempt {
    param(
        [Parameter(Mandatory = $true)][int]$AttemptIndex,
        [Parameter(Mandatory = $true)][string]$LabVIEWCliPath,
        [Parameter(Mandatory = $true)][string]$LabVIEWExePath,
        [Parameter(Mandatory = $true)][string]$CompileDirectory,
        [Parameter(Mandatory = $true)][string]$Port,
        [Parameter(Mandatory = $true)][string]$RunRoot
    )

    $attemptName = "masscompile-attempt{0}" -f $AttemptIndex
    $attemptLogPath = Join-Path $RunRoot ($attemptName + '.log')
    $args = @(
        '-LogToConsole', 'TRUE',
        '-LabVIEWPath', $LabVIEWExePath,
        '-OperationName', 'MassCompile',
        '-DirectoryToCompile', $CompileDirectory,
        '-PortNumber', $Port,
        '-Headless'
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $LabVIEWCliPath @args 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $lines = @()
    foreach ($line in @($output)) {
        if ($null -eq $line) {
            continue
        }
        $text = [string]$line
        Write-Host $text
        $lines += $text
    }
    Set-Content -LiteralPath $attemptLogPath -Value $lines -Encoding utf8

    $containsMinus350000 = ($lines -join "`n") -match '-350000'
    return [pscustomobject]@{
        AttemptName         = $attemptName
        ExitCode            = $exitCode
        LogPath             = $attemptLogPath
        ContainsMinus350000 = $containsMinus350000
    }
}

if ([string]::IsNullOrWhiteSpace($LvYear)) {
    throw 'LvYear must not be empty.'
}
if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) {
    $LabVIEWPath = "C:\Program Files\National Instruments\LabVIEW $LvYear\LabVIEW.exe"
}
if ([string]::IsNullOrWhiteSpace($DirectoryToCompile)) {
    $DirectoryToCompile = "C:\Program Files\National Instruments\LabVIEW $LvYear\examples\Arrays"
}
if ($MaxCliAttempts -lt 1) {
    throw 'MaxCliAttempts must be >= 1.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$resolvedLogRoot = if ([System.IO.Path]::IsPathRooted($LogRoot)) { $LogRoot } else { Join-Path $repoRoot $LogRoot }
Ensure-Directory -Path $resolvedLogRoot

$runTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLogRoot = Join-Path $resolvedLogRoot ("native-single-run-{0}" -f $runTimestamp)
Ensure-Directory -Path $runLogRoot
$diagRoot = Join-Path $runLogRoot 'verify-diag'
Ensure-Directory -Path $diagRoot

$preflightPath = Join-Path $runLogRoot 'preflight.txt'
$portStatusPath = Join-Path $diagRoot 'port-status.txt'
$netBeforePath = Join-Path $diagRoot 'netstat-before-cli.txt'
$netAfterPath = Join-Path $diagRoot 'netstat-after-cli.txt'
$processPath = Join-Path $diagRoot 'processes.txt'
$portConfigPath = Join-Path $diagRoot 'port-config.txt'

$labviewProcess = $null
$stepHistory = @()
$portListeningBeforeCli = $false
$firstAttemptExit = -1
$secondAttemptExit = $null
$containsMinus350000 = $false
$finalExitCode = 1
$failureMessage = ''

$lvIniPath = Join-Path (Split-Path -Parent $LabVIEWPath) 'LabVIEW.ini'
$cliIniCandidates = @(
    'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini',
    'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini'
)
$cliIniPath = $cliIniCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

@(
    "timestamp=$((Get-Date).ToString('o'))",
    "lv_year=$LvYear",
    "labview_path=$LabVIEWPath",
    "lv_cli_port=$LvCliPort",
    "directory_to_compile=$DirectoryToCompile",
    "max_cli_attempts=$MaxCliAttempts"
) | Set-Content -LiteralPath $preflightPath -Encoding ascii

try {
    if (-not (Test-Path -LiteralPath $LabVIEWPath -PathType Leaf)) {
        throw "LabVIEW executable not found at $LabVIEWPath"
    }
    if (-not (Test-Path -LiteralPath $DirectoryToCompile -PathType Container)) {
        throw "DirectoryToCompile not found: $DirectoryToCompile"
    }

    $lvCliCommand = Get-Command -Name LabVIEWCLI -ErrorAction SilentlyContinue
    if ($null -eq $lvCliCommand) {
        throw 'LabVIEWCLI is not available on PATH.'
    }

    $serverTcpEnabled = Get-IniKeyValue -IniPath $lvIniPath -Key 'server.tcp.enabled'
    $serverTcpPort = Get-IniKeyValue -IniPath $lvIniPath -Key 'server.tcp.port'
    $defaultPort = if ($null -ne $cliIniPath) { Get-IniKeyValue -IniPath $cliIniPath -Key 'DefaultPortNumber' } else { $null }
    @(
        "labview_ini=$lvIniPath",
        "labview_cli_ini=$cliIniPath",
        "server.tcp.enabled=$serverTcpEnabled",
        "server.tcp.port=$serverTcpPort",
        "DefaultPortNumber=$defaultPort"
    ) | Set-Content -LiteralPath $portConfigPath -Encoding ascii

    try {
        $labviewProcess = Start-Process -FilePath $LabVIEWPath -WindowStyle Hidden -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 10
    }
    catch {
        Write-Warning ("Failed to prelaunch LabVIEW headless: " + $_.Exception.Message)
    }

    $netBefore = netstat -ano
    Set-Content -LiteralPath $netBeforePath -Value $netBefore -Encoding utf8
    $listenPattern = ':{0}\s+.*LISTENING' -f [regex]::Escape($LvCliPort)
    $listenLines = @($netBefore | Select-String -Pattern $listenPattern)
    $portListeningBeforeCli = $listenLines.Count -gt 0
    @(
        "port=$LvCliPort",
        "listening_count=$($listenLines.Count)",
        "port_listening_before_cli=$portListeningBeforeCli"
    ) | Set-Content -LiteralPath $portStatusPath -Encoding ascii
    if ($listenLines.Count -gt 0) {
        $listenLines | ForEach-Object { $_.ToString() } | Set-Content -LiteralPath (Join-Path $diagRoot 'port-listening-lines.txt') -Encoding ascii
    }

    $attempt1 = Invoke-MassCompileAttempt `
        -AttemptIndex 1 `
        -LabVIEWCliPath $lvCliCommand.Source `
        -LabVIEWExePath $LabVIEWPath `
        -CompileDirectory $DirectoryToCompile `
        -Port $LvCliPort `
        -RunRoot $runLogRoot
    $stepHistory += [pscustomobject]@{ step = $attempt1.AttemptName; exit_code = $attempt1.ExitCode; log_path = $attempt1.LogPath }
    $firstAttemptExit = [int]$attempt1.ExitCode
    $containsMinus350000 = [bool]$attempt1.ContainsMinus350000

    if ($attempt1.ExitCode -ne 0 -and $attempt1.ContainsMinus350000 -and $MaxCliAttempts -ge 2) {
        Start-Sleep -Seconds 10
        $attempt2 = Invoke-MassCompileAttempt `
            -AttemptIndex 2 `
            -LabVIEWCliPath $lvCliCommand.Source `
            -LabVIEWExePath $LabVIEWPath `
            -CompileDirectory $DirectoryToCompile `
            -Port $LvCliPort `
            -RunRoot $runLogRoot
        $stepHistory += [pscustomobject]@{ step = $attempt2.AttemptName; exit_code = $attempt2.ExitCode; log_path = $attempt2.LogPath }
        $secondAttemptExit = [int]$attempt2.ExitCode
        if ($attempt2.ContainsMinus350000) {
            $containsMinus350000 = $true
        }
    }

    if ($null -ne $secondAttemptExit) {
        $finalExitCode = [int]$secondAttemptExit
    }
    else {
        $finalExitCode = [int]$firstAttemptExit
    }
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    $netAfter = netstat -ano
    Set-Content -LiteralPath $netAfterPath -Value $netAfter -Encoding utf8
    Get-Process | Sort-Object ProcessName | Select-Object ProcessName, Id, Path | Out-File -FilePath $processPath -Encoding utf8

    $tempRoot = Join-Path $diagRoot 'lvtemporary'
    Ensure-Directory -Path $tempRoot
    Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'lvtemporary_*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tempRoot $_.Name) -Force
    }

    $userLogRoot = Join-Path $diagRoot 'labview-user-logs'
    Ensure-Directory -Path $userLogRoot
    $userTemp = [System.IO.Path]::GetTempPath()
    Get-ChildItem -LiteralPath $userTemp -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'LabVIEW*' -or $_.Name -like 'LabVIEWCLI*'
    } | Select-Object -First 200 | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $userLogRoot $_.Name) -Force
    }

    if (Test-Path -LiteralPath $lvIniPath -PathType Leaf) {
        Copy-Item -LiteralPath $lvIniPath -Destination (Join-Path $diagRoot 'LabVIEW.ini') -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($cliIniPath) -and (Test-Path -LiteralPath $cliIniPath -PathType Leaf)) {
        Copy-Item -LiteralPath $cliIniPath -Destination (Join-Path $diagRoot 'LabVIEWCLI.ini') -Force
    }

    if ($null -ne $labviewProcess) {
        try {
            Stop-Process -Id $labviewProcess.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning ("Unable to stop prelaunched LabVIEW process id $($labviewProcess.Id).")
        }
    }

    $summary = [ordered]@{
        timestamp_utc             = (Get-Date).ToUniversalTime().ToString('o')
        execution_surface         = 'native-host'
        lv_year                   = $LvYear
        labview_path              = $LabVIEWPath
        lv_cli_port               = $LvCliPort
        directory_to_compile      = $DirectoryToCompile
        max_cli_attempts          = $MaxCliAttempts
        port_listening_before_cli = $portListeningBeforeCli
        first_attempt_exit        = $firstAttemptExit
        second_attempt_exit       = $secondAttemptExit
        contains_minus_350000     = $containsMinus350000
        final_exit_code           = $finalExitCode
        run_succeeded             = ($finalExitCode -eq 0 -and -not $containsMinus350000)
        failure_message           = $failureMessage
        logs_path                 = $runLogRoot
        step_history              = $stepHistory
    }

    $summaryPath = Join-Path $runLogRoot 'summary.json'
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding ascii
    Write-Host "summary_path=$summaryPath"
}

if ($finalExitCode -ne 0 -or $containsMinus350000) {
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = "Native MassCompile verification failed. See logs at $runLogRoot"
    }
    throw $failureMessage
}

Write-Host 'Native MassCompile verification succeeded.'
