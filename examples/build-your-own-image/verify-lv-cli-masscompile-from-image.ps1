[CmdletBinding()]
param(
    [string]$ImageTag = 'labview-custom-windows:2020q1-windows-p3363-candidate',
    [string]$LvYear = '2020',
    [string]$LvCliPort = '3363',
    [string]$DirectoryToCompile = '',
    [int]$WarmupSeconds = 60,
    [int]$ListenPollTimeoutSeconds = 180,
    [int]$MaxCliAttempts = 2,
    [ValidateSet('process', 'hyperv')]
    [string]$IsolationMode = 'process',
    [switch]$KeepContainer,
    [string]$LogRoot = 'TestResults/agent-logs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [int[]]$AllowedExitCodes = @(0),
        [string]$LogPath = ''
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & docker @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    foreach ($line in @($output)) {
        if ($null -eq $line) {
            continue
        }
        $text = [string]$line
        Write-Host $text
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Add-Content -Path $LogPath -Value $text
        }
    }

    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "$Description failed with exit code $exitCode."
    }

    return $exitCode
}

function Invoke-ContainerPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$StepName,
        [Parameter(Mandatory = $true)][string]$CommandText,
        [Parameter(Mandatory = $true)][string]$RunLogRoot,
        [int[]]$AllowedExitCodes = @()
    )

    $stepLogPath = Join-Path $RunLogRoot ($StepName + '.log')
    New-Item -Path $stepLogPath -ItemType File -Force | Out-Null
    $args = @(
        'exec',
        $ContainerName,
        'powershell',
        '-NoProfile',
        '-Command', $CommandText
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & docker @args 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    foreach ($line in @($output)) {
        if ($null -eq $line) {
            continue
        }
        $text = [string]$line
        Add-Content -Path $stepLogPath -Value $text
        Write-Host $text
    }

    if ($AllowedExitCodes.Count -gt 0 -and ($AllowedExitCodes -notcontains $exitCode)) {
        throw "Container step '$StepName' failed with exit code $exitCode. See $stepLogPath"
    }

    return [pscustomobject]@{
        StepName = $StepName
        ExitCode = $exitCode
        LogPath  = $stepLogPath
    }
}

function Remove-ContainerIfPresent {
    param([string]$ContainerName)

    if ([string]::IsNullOrWhiteSpace($ContainerName)) {
        return
    }

    & docker container inspect $ContainerName > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        & docker rm -f $ContainerName > $null 2>&1
    }
}

if ($WarmupSeconds -lt 0) {
    throw 'WarmupSeconds must be >= 0.'
}
if ($ListenPollTimeoutSeconds -lt 1) {
    throw 'ListenPollTimeoutSeconds must be >= 1.'
}
if ($MaxCliAttempts -lt 1) {
    throw 'MaxCliAttempts must be >= 1.'
}
$LvCliPort = $LvCliPort.Trim()
if ($LvCliPort -ne '3363') {
    throw "LvCliPort must be '3363'. Received: '$LvCliPort'"
}
$LvYear = $LvYear.Trim()
if ([string]::IsNullOrWhiteSpace($LvYear)) {
    throw 'LvYear must not be empty.'
}
if ([string]::IsNullOrWhiteSpace($DirectoryToCompile)) {
    $DirectoryToCompile = "C:\Program Files\National Instruments\LabVIEW $LvYear\examples\Arrays"
}
$IsolationMode = $IsolationMode.Trim().ToLowerInvariant()

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$resolvedLogRoot = if ([System.IO.Path]::IsPathRooted($LogRoot)) { $LogRoot } else { Join-Path $repoRoot $LogRoot }
New-Item -Path $resolvedLogRoot -ItemType Directory -Force | Out-Null

$runTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLogRoot = Join-Path $resolvedLogRoot ("p3363-single-run-{0}" -f $runTimestamp)
New-Item -Path $runLogRoot -ItemType Directory -Force | Out-Null

$preflightPath = Join-Path $runLogRoot 'preflight.txt'

try {
    $dockerServerOs = (& docker version --format '{{.Server.Os}}' 2>$null).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to query Docker server mode. Ensure Docker Desktop is running.'
    }
    if ($dockerServerOs -ne 'windows') {
        throw "Docker server is not in Windows mode. Current server OS: $dockerServerOs"
    }

    & docker image inspect $ImageTag > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Image not found locally: $ImageTag"
    }
}
catch {
    throw $_
}

@(
    "timestamp=$((Get-Date).ToString('o'))",
    "image_tag=$ImageTag",
    "lv_year=$LvYear",
    "lv_cli_port=$LvCliPort",
    "directory_to_compile=$DirectoryToCompile",
    "warmup_seconds=$WarmupSeconds",
    "listen_poll_timeout_seconds=$ListenPollTimeoutSeconds",
    "max_cli_attempts=$MaxCliAttempts",
    "isolation_mode=$IsolationMode"
) | Set-Content -Path $preflightPath -Encoding ascii

$containerName = "p3363-verify-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$containerCreated = $false
$containerKept = $false
$stepHistory = @()
$portListeningBeforeCli = $false
$firstAttemptExit = -1
$secondAttemptExit = $null
$containsMinus350000 = $false
$finalExitCode = 1
$failureMessage = ''

$iniCheckTemplate = @'
$ErrorActionPreference = 'Stop'
$expectedPort = '__PORT__'
$lvIni = 'C:\Program Files\National Instruments\LabVIEW __YEAR__\LabVIEW.ini'
$cliIni = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini'
if (-not (Test-Path -LiteralPath $lvIni -PathType Leaf)) { Write-Host ('MISSING=' + $lvIni); exit 21 }
if (-not (Test-Path -LiteralPath $cliIni -PathType Leaf)) { Write-Host ('MISSING=' + $cliIni); exit 22 }
$lvTokens = Get-Content -LiteralPath $lvIni | Where-Object { $_ -match '^server\.tcp\.(enabled|port)=' }
$cliTokens = Get-Content -LiteralPath $cliIni | Where-Object { $_ -match '^DefaultPortNumber\s*=' }
$lvTokens | ForEach-Object { Write-Host $_ }
$cliTokens | ForEach-Object { Write-Host $_ }
$lvMatch = $lvTokens -contains ('server.tcp.port=' + $expectedPort)
$cliMatch = (($cliTokens | Where-Object { $_ -match ('^DefaultPortNumber\s*=\s*' + [regex]::Escape($expectedPort) + '$') }).Count -gt 0)
if ($lvMatch -and $cliMatch) { Write-Host 'INI_PORT_MATCH=true'; exit 0 }
Write-Host 'INI_PORT_MATCH=false'
exit 23
'@

$readinessTemplate = @'
$ErrorActionPreference = 'Continue'
$lvExe = 'C:\Program Files\National Instruments\LabVIEW __YEAR__\LabVIEW.exe'
$port = '__PORT__'
$altPort = if ($port -eq '3363') { '3366' } else { '3363' }
$warmup = __WARMUP__
$timeout = __TIMEOUT__
if (-not (Test-Path -LiteralPath $lvExe -PathType Leaf)) { Write-Host ('MISSING=' + $lvExe); exit 31 }
Start-Process -FilePath $lvExe -ArgumentList '--headless' -WindowStyle Hidden | Out-Null
if ($warmup -gt 0) {
  Write-Host ('WARMUP_SECONDS=' + $warmup)
  Start-Sleep -Seconds $warmup
}
$deadline = (Get-Date).AddSeconds($timeout)
$pattern = ':' + [regex]::Escape($port) + '\s+.*LISTENING'
$altPattern = ':' + [regex]::Escape($altPort) + '\s+.*LISTENING'
$isListening = $false
$tick = 0
while ((Get-Date) -lt $deadline) {
  $tick += 1
  $now = (Get-Date).ToString('o')
  $proc = @(Get-Process -Name 'LabVIEW*' -ErrorAction SilentlyContinue)
  $procCount = $proc.Count
  $procNames = if ($procCount -gt 0) { (($proc | Select-Object -ExpandProperty ProcessName -Unique) -join ',') } else { '<none>' }
  $net = netstat -ano
  $matches = @($net | Select-String -Pattern $pattern)
  $altMatches = @($net | Select-String -Pattern $altPattern)
  Write-Host ('TICK=' + $tick + ';TIME=' + $now + ';LABVIEW_PROC_COUNT=' + $procCount + ';LABVIEW_PROCS=' + $procNames + ';LISTEN_' + $port + '=' + $matches.Count + ';LISTEN_' + $altPort + '=' + $altMatches.Count)
  if ($matches.Count -gt 0) { $isListening = $true; break }
  Start-Sleep -Seconds 2
}
if ($isListening) {
  Write-Host 'PORT_LISTENING=true'
  netstat -ano | Select-String -Pattern $pattern | ForEach-Object { $_.ToString() }
  netstat -ano | Select-String -Pattern $altPattern | ForEach-Object { $_.ToString() }
} else {
  Write-Host 'PORT_LISTENING=false'
}
exit 0
'@

$massCompileTemplate = @'
$ErrorActionPreference = 'Continue'
$lvExe = 'C:\Program Files\National Instruments\LabVIEW __YEAR__\LabVIEW.exe'
$target = '__DIR__'
$port = '__PORT__'
if (-not (Test-Path -LiteralPath $lvExe -PathType Leaf)) { Write-Host ('MISSING=' + $lvExe); exit 41 }
if (-not (Test-Path -LiteralPath $target -PathType Container)) { Write-Host ('MISSING=' + $target); exit 42 }
& LabVIEWCLI -LogToConsole TRUE -LabVIEWPath $lvExe -OperationName MassCompile -DirectoryToCompile $target -PortNumber $port -Headless
$code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
Write-Host ('ATTEMPT_EXIT_CODE=' + $code)
exit $code
'@

$diagnosticsTemplate = @'
$ErrorActionPreference = 'Continue'
$port = '__PORT__'
$lvYear = '__YEAR__'
$diagRoot = 'C:\ni\temp\verify-diag'
New-Item -Path $diagRoot -ItemType Directory -Force | Out-Null
$lvIni = 'C:\Program Files\National Instruments\LabVIEW ' + $lvYear + '\LabVIEW.ini'
$cliIni = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini'
if (Test-Path -LiteralPath $lvIni -PathType Leaf) { Copy-Item -LiteralPath $lvIni -Destination (Join-Path $diagRoot 'LabVIEW.ini') -Force }
if (Test-Path -LiteralPath $cliIni -PathType Leaf) { Copy-Item -LiteralPath $cliIni -Destination (Join-Path $diagRoot 'LabVIEWCLI.ini') -Force }
$net = netstat -ano
$net | Out-File -Encoding utf8 (Join-Path $diagRoot 'netstat.txt')
$altPort = if ($port -eq '3363') { '3366' } else { '3363' }
$listen = @($net | Select-String -Pattern (':' + [regex]::Escape($port) + '\s+.*LISTENING'))
$listenAlt = @($net | Select-String -Pattern (':' + [regex]::Escape($altPort) + '\s+.*LISTENING'))
@(
  'port=' + $port,
  'alternate_port=' + $altPort,
  ('listening_count_' + $port + '=' + $listen.Count),
  ('listening_count_' + $altPort + '=' + $listenAlt.Count)
) | Set-Content -Path (Join-Path $diagRoot 'port-status.txt') -Encoding ascii
if ($listen.Count -gt 0) { $listen | ForEach-Object { $_.ToString() } | Set-Content -Path (Join-Path $diagRoot 'port-listening-lines.txt') -Encoding ascii }
if ($listenAlt.Count -gt 0) { $listenAlt | ForEach-Object { $_.ToString() } | Set-Content -Path (Join-Path $diagRoot 'alternate-port-listening-lines.txt') -Encoding ascii }
Get-Process | Sort-Object ProcessName | Select-Object ProcessName,Id,Path | Out-File -Encoding utf8 (Join-Path $diagRoot 'processes.txt')
$tempRoot = Join-Path $diagRoot 'lvtemporary'
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'lvtemporary_*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tempRoot $_.Name) -Force
}
$userRoot = Join-Path $diagRoot 'labview-user-logs'
New-Item -Path $userRoot -ItemType Directory -Force | Out-Null
$roots = @('C:\Users\ContainerAdministrator\AppData\Local\Temp', 'C:\Users\ContainerAdministrator\AppData\Local', 'C:\Users\ContainerAdministrator\AppData\Roaming')
$patterns = @('LabVIEWCLI*_cur.txt', 'LabVIEW*_cur.txt', 'LabVIEWCLI*.log', 'LabVIEW*.log')
foreach ($root in $roots) {
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
  foreach ($pat in $patterns) {
    Get-ChildItem -Path $root -Recurse -File -Filter $pat -ErrorAction SilentlyContinue | Select-Object -First 200 | ForEach-Object {
      $name = ($_.DirectoryName -replace '[:\\ ]', '_') + '_' + $_.Name
      $dest = Join-Path $userRoot $name
      if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { Copy-Item -LiteralPath $_.FullName -Destination $dest -Force }
    }
  }
}
exit 0
'@

$iniCheckCmd = $iniCheckTemplate.Replace('__PORT__', $LvCliPort).Replace('__YEAR__', $LvYear)
$readinessCmd = $readinessTemplate.Replace('__PORT__', $LvCliPort).Replace('__YEAR__', $LvYear).Replace('__WARMUP__', [string]$WarmupSeconds).Replace('__TIMEOUT__', [string]$ListenPollTimeoutSeconds)
$massCompileCmd = $massCompileTemplate.Replace('__PORT__', $LvCliPort).Replace('__YEAR__', $LvYear).Replace('__DIR__', ($DirectoryToCompile -replace "'", "''"))
$diagnosticsCmd = $diagnosticsTemplate.Replace('__PORT__', $LvCliPort).Replace('__YEAR__', $LvYear)

try {
    $dockerRunLogPath = Join-Path $runLogRoot 'docker-run.log'
    New-Item -Path $dockerRunLogPath -ItemType File -Force | Out-Null
    $dockerRunArgs = @('run')
    if ($IsolationMode -eq 'hyperv') {
        $dockerRunArgs += '--isolation=hyperv'
    }
    $dockerRunArgs += @('--name', $containerName, '--detach', $ImageTag, 'powershell', '-NoProfile', '-Command', 'Start-Sleep -Seconds 21600')
    Invoke-DockerCommand -Arguments $dockerRunArgs -Description 'start verifier container' -LogPath $dockerRunLogPath | Out-Null
    $containerCreated = $true

    $iniResult = Invoke-ContainerPowerShell -ContainerName $containerName -StepName 'ini-check' -CommandText $iniCheckCmd -RunLogRoot $runLogRoot -AllowedExitCodes @(0)
    $stepHistory += $iniResult

    $readinessResult = Invoke-ContainerPowerShell -ContainerName $containerName -StepName 'readiness' -CommandText $readinessCmd -RunLogRoot $runLogRoot -AllowedExitCodes @(0)
    $stepHistory += $readinessResult
    $portListeningBeforeCli = ((Get-Content -LiteralPath $readinessResult.LogPath -Raw) -match 'PORT_LISTENING=true')

    $attempt1 = Invoke-ContainerPowerShell -ContainerName $containerName -StepName 'masscompile-attempt1' -CommandText $massCompileCmd -RunLogRoot $runLogRoot
    $stepHistory += $attempt1
    $firstAttemptExit = $attempt1.ExitCode
    $attempt1Log = Get-Content -LiteralPath $attempt1.LogPath -Raw
    $attempt1Has350000 = $attempt1Log -match '-350000'
    $containsMinus350000 = $attempt1Has350000

    if ($firstAttemptExit -ne 0 -and $attempt1Has350000 -and $MaxCliAttempts -ge 2) {
        Start-Sleep -Seconds 10
        $attempt2 = Invoke-ContainerPowerShell -ContainerName $containerName -StepName 'masscompile-attempt2' -CommandText $massCompileCmd -RunLogRoot $runLogRoot
        $stepHistory += $attempt2
        $secondAttemptExit = $attempt2.ExitCode
        $attempt2Log = Get-Content -LiteralPath $attempt2.LogPath -Raw
        if ($attempt2Log -match '-350000') {
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
    if ($containerCreated) {
        try {
            $diagResult = Invoke-ContainerPowerShell -ContainerName $containerName -StepName 'diagnostics' -CommandText $diagnosticsCmd -RunLogRoot $runLogRoot
            $stepHistory += $diagResult
        }
        catch {
            Write-Warning ('Diagnostics capture command failed: ' + $_.Exception.Message)
        }

        & docker stop $containerName > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to stop container '$containerName'."
        }

        $copyLogPath = Join-Path $runLogRoot 'docker-cp.log'
        New-Item -Path $copyLogPath -ItemType File -Force | Out-Null
        try {
            Invoke-DockerCommand -Arguments @('cp', ($containerName + ':C:\ni\temp\verify-diag'), $runLogRoot) -Description 'copy diagnostics' -LogPath $copyLogPath | Out-Null
        }
        catch {
            Write-Warning ('Diagnostics copy failed: ' + $_.Exception.Message)
        }

        if ($KeepContainer.IsPresent) {
            $containerKept = $true
        }
        else {
            Remove-ContainerIfPresent -ContainerName $containerName
        }
    }

    $summary = [ordered]@{
        timestamp_utc               = (Get-Date).ToUniversalTime().ToString('o')
        image_tag                   = $ImageTag
        container_name              = $containerName
        container_kept              = $containerKept
        lv_year                     = $LvYear
        lv_cli_port                 = $LvCliPort
        directory_to_compile        = $DirectoryToCompile
        warmup_seconds              = $WarmupSeconds
        listen_poll_timeout_seconds = $ListenPollTimeoutSeconds
        max_cli_attempts            = $MaxCliAttempts
        isolation_mode              = $IsolationMode
        port_listening_before_cli   = $portListeningBeforeCli
        first_attempt_exit          = $firstAttemptExit
        second_attempt_exit         = $secondAttemptExit
        contains_minus_350000       = $containsMinus350000
        final_exit_code             = $finalExitCode
        run_succeeded               = ($finalExitCode -eq 0 -and -not $containsMinus350000)
        failure_message             = $failureMessage
        logs_path                   = $runLogRoot
        step_history                = $stepHistory
    }

    $summaryPath = Join-Path $runLogRoot 'summary.json'
    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding ascii
    Write-Host "summary_path=$summaryPath"
}

if ($finalExitCode -ne 0 -or $containsMinus350000) {
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = "MassCompile verification failed. See logs at $runLogRoot"
    }
    throw $failureMessage
}

Write-Host 'MassCompile verification succeeded.'
