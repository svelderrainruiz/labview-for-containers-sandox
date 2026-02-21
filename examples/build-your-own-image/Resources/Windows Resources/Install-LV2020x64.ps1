[CmdletBinding()]
param(
    [string]$LvYear = $env:LV_YEAR,
    [string]$LvFeedLocation = $env:LV_FEED_LOCATION,
    [string]$LvCorePackage = $env:LV_CORE_PACKAGE,
    [string]$LvCliPackage = $env:LV_CLI_PACKAGE,
    [string]$LvCliPort = $env:LV_CLI_PORT,
    [string]$PersistRoot = 'C:\lv-persist',
    [string]$StateFileName = 'state.json',
    [string]$InstallLogName = 'install.log',
    [string]$SessionId = $env:LV_INSTALL_SESSION_ID,
    [int]$PhaseIndex = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LvYear)) { $LvYear = '2020' }
if ([string]::IsNullOrWhiteSpace($LvCorePackage)) { $LvCorePackage = 'ni-labview-2020-core-en' }
if ([string]::IsNullOrWhiteSpace($LvCliPackage)) { $LvCliPackage = 'ni-labview-command-line-interface-x86' }
if ([string]::IsNullOrWhiteSpace($LvCliPort)) { $LvCliPort = '3363' }
$LvCliPort = $LvCliPort.Trim()
if ($LvCliPort -ne '3363') {
    throw "LvCliPort must be set to '3363' for lv2020x64 installs. Received: '$LvCliPort'"
}

$installOptionalHelp = $env:INSTALL_OPTIONAL_HELP
if ([string]::IsNullOrWhiteSpace($installOptionalHelp)) { $installOptionalHelp = '0' }

$script:NipkgExe = $env:NIPKG_EXE
if ([string]::IsNullOrWhiteSpace($script:NipkgExe)) {
    $script:NipkgExe = 'C:\Program Files\National Instruments\NI Package Manager\nipkg.exe'
}

New-Item -Path $PersistRoot -ItemType Directory -Force | Out-Null
$statePath = Join-Path $PersistRoot $StateFileName
$installLogPath = Join-Path $PersistRoot $InstallLogName
$script:LastInstallerExitCode = 0
$script:CurrentResumeCursor = ''
$script:CurrentMandatoryPackage = ''
$script:AttemptCounter = 1
$script:PreviousStateSchemaVersion = ''

function Convert-ToIntOrNull {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Read-PreviousState {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Write-Warning "Existing state file at '$Path' is not valid JSON. Continuing with defaults."
        return $null
    }
}

function Get-PendingRebootKeys {
    $hits = @()

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $hits += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $hits += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }

    try {
        $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($null -ne $sessionManager -and $null -ne $sessionManager.PendingFileRenameOperations -and @($sessionManager.PendingFileRenameOperations).Count -gt 0) {
            $hits += 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
        }
    }
    catch {
        # Ignore key read failures and keep reboot detection best-effort.
    }

    return @($hits)
}

$previousState = Read-PreviousState -Path $statePath
if ($null -ne $previousState) {
    if (-not [string]::IsNullOrWhiteSpace([string]$previousState.schema_version)) {
        $script:PreviousStateSchemaVersion = [string]$previousState.schema_version
    }
    else {
        # Backward compatibility with pre-v2 state payload.
        $script:PreviousStateSchemaVersion = '1.0'
    }

    $previousAttempt = Convert-ToIntOrNull -Value $previousState.attempt_counter
    if ($null -ne $previousAttempt -and $previousAttempt -ge 1) {
        $script:AttemptCounter = $previousAttempt + 1
    }

    if ([string]::IsNullOrWhiteSpace($SessionId) -and -not [string]::IsNullOrWhiteSpace([string]$previousState.session_id)) {
        $SessionId = [string]$previousState.session_id
    }

    if ($PhaseIndex -le 0) {
        $previousPhaseIndex = Convert-ToIntOrNull -Value $previousState.phase_index
        if ($null -ne $previousPhaseIndex -and $previousPhaseIndex -ge 1) {
            $PhaseIndex = $previousPhaseIndex + 1
        }
    }
}

if ([string]::IsNullOrWhiteSpace($SessionId)) {
    $SessionId = [Guid]::NewGuid().ToString()
}
if ($PhaseIndex -le 0) {
    $PhaseIndex = 1
}

function Write-State {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$Message,
        [string]$Step = '',
        [string]$ResumeCursor = '',
        [string]$MandatoryPackage = '',
        [string[]]$RebootPendingKeys = @(),
        [bool]$PendingRebootDetected = $false,
        [int]$InstallerExitCode = 0,
        [int]$AttemptCounter = 1
    )

    if ([string]::IsNullOrWhiteSpace($ResumeCursor)) {
        $ResumeCursor = $script:CurrentResumeCursor
    }
    if ([string]::IsNullOrWhiteSpace($MandatoryPackage)) {
        $MandatoryPackage = $script:CurrentMandatoryPackage
    }

    $normalizedRebootPendingKeys = @($RebootPendingKeys)

    $payload = [ordered]@{
        schema_version     = '2.0'
        timestamp_utc     = (Get-Date).ToUniversalTime().ToString('o')
        session_id        = $SessionId
        phase_index       = $PhaseIndex
        attempt_counter   = $AttemptCounter
        status            = $Status
        exit_code         = $ExitCode
        step              = $Step
        resume_cursor     = $ResumeCursor
        mandatory_package = $MandatoryPackage
        reboot_pending_keys = $normalizedRebootPendingKeys
        pending_reboot_detected = $PendingRebootDetected
        installer_exit_code = $InstallerExitCode
        previous_state_schema_version = $script:PreviousStateSchemaVersion
        message           = $Message
        lv_year           = $LvYear
        lv_feed_location  = $LvFeedLocation
        lv_core_package   = $LvCorePackage
        lv_cli_package    = $LvCliPackage
        lv_cli_port       = $LvCliPort
        installer_log     = $installLogPath
    }

    $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding utf8
}

function Append-InstallLog {
    param([string]$Text)

    $line = "[{0}] {1}" -f (Get-Date).ToString('o'), $Text
    Add-Content -Path $installLogPath -Value $line
}

function Invoke-Nipkg {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$StepName,
        [switch]$AllowRebootRequired,
        [switch]$IgnoreFailure
    )

    $commandText = "nipkg {0}" -f ($Arguments -join ' ')
    Write-Host "Running ${StepName}: $commandText"
    Append-InstallLog -Text "Running ${StepName}: $commandText"

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $script:NipkgExe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $script:LastInstallerExitCode = if ($null -eq $exitCode) { 0 } else { [int]$exitCode }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $outputText = if ($null -eq $output) { '' } else { (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }

    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText
        Append-InstallLog -Text $outputText
    }

    if ($exitCode -eq 0) {
        return [pscustomobject]@{
            ExitCode    = 0
            NeedsReboot = $false
            InstallerExitCode = 0
            Output      = $outputText
        }
    }

    $needsReboot = ($outputText -match '-125071') -or ($outputText -match 'A system reboot is needed')
    if ($AllowRebootRequired -and $needsReboot) {
        return [pscustomobject]@{
            ExitCode    = 194
            NeedsReboot = $true
            InstallerExitCode = [int]$exitCode
            Output      = $outputText
        }
    }

    if ($IgnoreFailure) {
        Write-Warning "$StepName failed with exit code $exitCode and will be ignored."
        Append-InstallLog -Text "$StepName failed with exit code $exitCode and was ignored."
        return [pscustomobject]@{
            ExitCode    = 0
            NeedsReboot = $false
            InstallerExitCode = [int]$exitCode
            Output      = $outputText
        }
    }

    throw "$StepName failed with exit code $exitCode."
}

function Set-IniValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement
    )

    $lines = Get-Content -Path $Path
    $matched = $false
    $updatedLines = foreach ($line in $lines) {
        if ($line -match $Pattern) {
            $matched = $true
            $Replacement
        }
        else {
            $line
        }
    }

    if (-not $matched) {
        $updatedLines += $Replacement
    }

    Set-Content -Path $Path -Value $updatedLines -Encoding ascii
}

function Finalize-Configuration {
    $labviewIniSource = 'C:\ni\resources\LabVIEW.ini'
    $labviewCliIniSource = 'C:\ni\resources\LabVIEWCLI.ini'
    $labviewIniTarget = "C:\Program Files\National Instruments\LabVIEW $LvYear\LabVIEW.ini"
    $labviewCliIniTarget = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini'

    if (-not (Test-Path -Path $labviewIniSource)) {
        throw "Expected file not found: $labviewIniSource"
    }
    if (-not (Test-Path -Path $labviewCliIniSource)) {
        throw "Expected file not found: $labviewCliIniSource"
    }
    if (-not (Test-Path -Path (Split-Path -Path $labviewIniTarget -Parent))) {
        throw "Expected LabVIEW installation folder not found for year $LvYear."
    }
    if (-not (Test-Path -Path (Split-Path -Path $labviewCliIniTarget -Parent))) {
        throw 'Expected LabVIEW CLI installation folder not found.'
    }

    Set-IniValue -Path $labviewIniSource -Pattern '^server\.tcp\.port=.*$' -Replacement "server.tcp.port=$LvCliPort"
    Set-IniValue -Path $labviewCliIniSource -Pattern '^DefaultPortNumber\s*=.*$' -Replacement "DefaultPortNumber = $LvCliPort"

    Copy-Item -Path $labviewIniSource -Destination $labviewIniTarget -Force
    Copy-Item -Path $labviewCliIniSource -Destination $labviewCliIniTarget -Force
}

try {
    if (-not (Test-Path -Path $script:NipkgExe)) {
        throw "NI Package Manager executable was not found at '$script:NipkgExe'."
    }
    if ([string]::IsNullOrWhiteSpace($LvFeedLocation)) {
        throw 'LV_FEED_LOCATION is required.'
    }

    $feedName = "LV$LvYear"
    Append-InstallLog -Text "Starting install flow for LabVIEW $LvYear."

    Invoke-Nipkg -Arguments @('feed-remove', $feedName) -StepName 'feed-remove-preflight' -IgnoreFailure | Out-Null
    Invoke-Nipkg -Arguments @('feed-add', "--name=$feedName", $LvFeedLocation) -StepName 'feed-add' | Out-Null
    Invoke-Nipkg -Arguments @('feed-update', $feedName) -StepName 'feed-update' | Out-Null

    $availableResult = Invoke-Nipkg -Arguments @('list') -StepName 'list-available' -IgnoreFailure
    $availableLines = $availableResult.Output -split "`r?`n" | Where-Object {
        $_ -match "ni-labview-$LvYear" -or $_ -match 'ni-labview-command-line-interface'
    }
    if ($availableLines.Count -gt 0) {
        Write-Host 'Available package IDs matching LabVIEW year/CLI:'
        $availableLines | ForEach-Object {
            Write-Host $_
            Append-InstallLog -Text $_
        }
    }
    else {
        Write-Host 'No filtered package IDs found in feed output.'
        Append-InstallLog -Text 'No filtered package IDs found in feed output.'
    }

    if ($installOptionalHelp -eq '1') {
        Invoke-Nipkg -Arguments @('install', '--accept-eulas', '-y', 'ni-offline-help-viewer') -StepName 'install-optional-help' -IgnoreFailure | Out-Null
    }
    else {
        Write-Host 'Skipping optional package ni-offline-help-viewer (INSTALL_OPTIONAL_HELP=0).'
        Append-InstallLog -Text 'Skipping optional package ni-offline-help-viewer (INSTALL_OPTIONAL_HELP=0).'
    }

    $mandatoryPackages = @(
        @{ Step = 'install-core'; Package = $LvCorePackage },
        @{ Step = 'install-cli'; Package = $LvCliPackage }
    )

    foreach ($package in $mandatoryPackages) {
        $script:CurrentResumeCursor = [string]$package.Step
        $script:CurrentMandatoryPackage = [string]$package.Package
        $installResult = Invoke-Nipkg -Arguments @('install', '--accept-eulas', '-y', $package.Package) -StepName $package.Step -AllowRebootRequired
        $pendingRebootKeys = @(Get-PendingRebootKeys)
        $pendingRebootDetected = $pendingRebootKeys.Count -gt 0
        if ($installResult.ExitCode -eq 194 -or $pendingRebootDetected) {
            $message = "Reboot-required checkpoint detected while installing '$($package.Package)'."
            if ($pendingRebootDetected -and $installResult.ExitCode -ne 194) {
                $message = "Pending reboot registry markers detected after '$($package.Package)'."
            }
            Write-State `
                -Status 'pending_reboot' `
                -ExitCode 194 `
                -Message $message `
                -Step $package.Step `
                -ResumeCursor $package.Step `
                -MandatoryPackage $package.Package `
                -RebootPendingKeys $pendingRebootKeys `
                -PendingRebootDetected $pendingRebootDetected `
                -InstallerExitCode $installResult.InstallerExitCode `
                -AttemptCounter $script:AttemptCounter
            Write-Host $message
            exit 194
        }
    }

    Invoke-Nipkg -Arguments @('feed-remove', $feedName) -StepName 'feed-remove' -IgnoreFailure | Out-Null
    Invoke-Nipkg -Arguments @('feed-update') -StepName 'feed-update-post-remove' -IgnoreFailure | Out-Null

    $packageCachePath = 'C:\ProgramData\National Instruments\NI Package Manager\packages'
    if (Test-Path -Path $packageCachePath) {
        Remove-Item -Path $packageCachePath -Recurse -Force
    }

    Finalize-Configuration
    $postConfigPendingRebootKeys = @(Get-PendingRebootKeys)
    if ($postConfigPendingRebootKeys.Count -gt 0) {
        $message = 'Pending reboot registry markers detected after configuration.'
        Write-State `
            -Status 'pending_reboot' `
            -ExitCode 194 `
            -Message $message `
            -Step 'post-config' `
            -ResumeCursor 'post-config' `
            -MandatoryPackage $script:CurrentMandatoryPackage `
            -RebootPendingKeys $postConfigPendingRebootKeys `
            -PendingRebootDetected $true `
            -InstallerExitCode $script:LastInstallerExitCode `
            -AttemptCounter $script:AttemptCounter
        Write-Host $message
        exit 194
    }

    Write-State `
        -Status 'completed' `
        -ExitCode 0 `
        -Message 'Installation and configuration completed successfully.' `
        -Step 'completed' `
        -ResumeCursor 'completed' `
        -MandatoryPackage $script:CurrentMandatoryPackage `
        -RebootPendingKeys @() `
        -PendingRebootDetected $false `
        -InstallerExitCode 0 `
        -AttemptCounter $script:AttemptCounter
    Write-Host 'LabVIEW installation and configuration completed successfully.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    $errorDetail = [ordered]@{
        exception_type = $_.Exception.GetType().FullName
        message = $message
    } | ConvertTo-Json -Compress -Depth 4
    Write-State `
        -Status 'failed' `
        -ExitCode 1 `
        -Message $errorDetail `
        -Step $script:CurrentResumeCursor `
        -ResumeCursor $script:CurrentResumeCursor `
        -MandatoryPackage $script:CurrentMandatoryPackage `
        -RebootPendingKeys @(Get-PendingRebootKeys) `
        -PendingRebootDetected $false `
        -InstallerExitCode $script:LastInstallerExitCode `
        -AttemptCounter $script:AttemptCounter
    Write-Error $message
    exit 1
}
