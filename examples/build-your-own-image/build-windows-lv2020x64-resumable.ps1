[CmdletBinding()]
param(
    [string]$ImageTag = 'labview-custom-windows:2020q1-windows',
    [Parameter(Mandatory = $true)][string]$LvFeedLocation,
    [string]$BaseImage = 'mcr.microsoft.com/windows/server:ltsc2022',
    [string]$PersistVolumeName = 'vm',
    [string]$Phase1Tag = '',
    [string]$Phase2Tag = '',
    [switch]$KeepIntermediate,
    [string]$LvYear = '2020',
    [string]$LvCorePackage = 'ni-labview-2020-core-en',
    [string]$LvCliPackage = 'ni-labview-command-line-interface-x86',
    [string]$LvCliPort = '3363',
    [ValidateSet('0', '1')][string]$InstallOptionalHelp = '0',
    [string]$DnsServer = '1.1.1.1',
    [string]$NipmInstallerDownloadUrl = 'https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager26.0.0.exe',
    [string]$NipmInstallerDownloadSha256 = 'A2AF381482F85ABA2A963676EAC436F96D69572A9EBFBAF85FF26C372A1995C3',
    [string]$NipmInstallerSourcePath = '',
    [ValidateRange(2, 12)][int]$MaxResumePhases = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LvCliPort = [string]$LvCliPort
if ([string]::IsNullOrWhiteSpace($LvCliPort)) {
    $LvCliPort = '3363'
}
$LvCliPort = $LvCliPort.Trim()
if ($LvCliPort -ne '3363') {
    throw "LvCliPort must be set to '3363' for the lv2020x64 image path. Received: '$LvCliPort'"
}
if ([string]::IsNullOrWhiteSpace($BaseImage)) {
    throw 'BaseImage cannot be empty.'
}
$BaseImage = $BaseImage.Trim()

function Get-DerivedImageTag {
    param(
        [Parameter(Mandatory = $true)][string]$BaseTag,
        [Parameter(Mandatory = $true)][string]$Suffix
    )

    if ($BaseTag -match '^(?<repo>.+):(?<tag>[^:]+)$') {
        return "{0}:{1}-{2}" -f $Matches['repo'], $Matches['tag'], $Suffix
    }

    return "{0}:{1}" -f $BaseTag, $Suffix
}

function Get-PhaseTag {
    param(
        [Parameter(Mandatory = $true)][int]$PhaseIndex
    )

    if ($PhaseIndex -eq 1 -and -not [string]::IsNullOrWhiteSpace($Phase1Tag)) {
        return $Phase1Tag
    }
    if ($PhaseIndex -eq 2 -and -not [string]::IsNullOrWhiteSpace($Phase2Tag)) {
        return $Phase2Tag
    }

    return (Get-DerivedImageTag -BaseTag $ImageTag -Suffix ("phase{0}" -f $PhaseIndex))
}

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Host "docker $($Arguments -join ' ')"
    & docker @Arguments
    $exitCode = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "$Description failed with exit code $exitCode."
    }

    return $exitCode
}

function Remove-ContainerIfPresent {
    param([string]$ContainerName)

    if ([string]::IsNullOrWhiteSpace($ContainerName)) {
        return
    }

    & docker container inspect $ContainerName *> $null
    if ($LASTEXITCODE -eq 0) {
        & docker rm -f $ContainerName *> $null
    }
}

function Remove-ImageIfPresent {
    param([string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        return
    }

    & docker image inspect $Tag *> $null
    if ($LASTEXITCODE -eq 0) {
        & docker image rm $Tag *> $null
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-ValidFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    return ((Get-Item -LiteralPath $Path).Length -gt 0)
}

function Test-HasNipmCompanionFiles {
    param([string]$InstallerPath)

    if (-not (Test-ValidFile -Path $InstallerPath)) {
        return $false
    }

    $installerDirectory = Split-Path -Parent $InstallerPath
    $requiredCompanions = @(
        'Install.exe.config',
        'nipkgclient.dll',
        'NationalInstruments.PackageManagement.Core.dll'
    )

    foreach ($companionFile in $requiredCompanions) {
        if (Test-Path -LiteralPath (Join-Path $installerDirectory $companionFile)) {
            return $true
        }
    }

    return $false
}

function Convert-ToDockerContainerPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    return ($Path -replace '\\', '/')
}

function Get-StateField {
    param(
        [object]$StateObject,
        [string]$FieldName
    )

    if ($null -eq $StateObject) {
        return ''
    }
    if ($StateObject -isnot [pscustomobject] -and $StateObject -isnot [hashtable]) {
        return ''
    }
    if (-not $StateObject.PSObject.Properties.Name.Contains($FieldName)) {
        return ''
    }

    return [string]$StateObject.$FieldName
}

function Get-InstallStateSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$PersistVolume,
        [Parameter(Mandatory = $true)][string]$ReaderImage
    )

    $stateReadCommand = @'
$statePath = 'C:\lv-persist\state.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  Get-Content -LiteralPath $statePath -Raw
}
'@

    $args = @(
        'run',
        '--rm',
        '--volume', ('{0}:C:\lv-persist' -f $PersistVolume),
        $ReaderImage,
        'powershell',
        '-NoProfile',
        '-Command', $stateReadCommand
    )

    $output = & docker @args 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        return [ordered]@{
            available = $false
            parse_ok = $false
            raw = ''
            error = "Unable to read persisted installer state (docker exit $exitCode)."
        }
    }

    $raw = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{
            available = $false
            parse_ok = $false
            raw = ''
            error = 'state.json is missing or empty.'
        }
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        return [ordered]@{
            available = $true
            parse_ok = $true
            raw = $raw
            parsed = $parsed
            error = ''
        }
    }
    catch {
        return [ordered]@{
            available = $true
            parse_ok = $false
            raw = $raw
            error = "state.json parse failure: $($_.Exception.Message)"
        }
    }
}

function Write-InstallerHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SourceLabel
    )

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    Write-Host "NIPM bootstrapper source: $SourceLabel"
    Write-Host "NIPM bootstrapper SHA256: $hash"
}

function Get-UpperInvariant {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return $Value.ToUpperInvariant()
}

function Ensure-NipmInstallerBootstrapper {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [string]$DownloadUrl,
        [string]$DownloadSha256,
        [string]$SourcePath
    )

    $installerDirectory = Split-Path -Parent $InstallerPath
    if (-not (Test-Path -LiteralPath $installerDirectory)) {
        New-Item -Path $installerDirectory -ItemType Directory -Force | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $resolvedSourcePath = (Resolve-Path -Path $SourcePath -ErrorAction Stop).Path
        $sourceItem = Get-Item -LiteralPath $resolvedSourcePath
        if ($sourceItem.PSIsContainer) {
            Copy-Item -Path (Join-Path $resolvedSourcePath '*') -Destination $installerDirectory -Recurse -Force
        }
        else {
            if (-not (Test-ValidFile -Path $resolvedSourcePath)) {
                throw "NIPM bootstrapper source path exists but is not a valid file: $resolvedSourcePath"
            }

            Copy-Item -LiteralPath $resolvedSourcePath -Destination $InstallerPath -Force
        }

        if (-not (Test-ValidFile -Path $InstallerPath)) {
            throw "Failed to copy NIPM bootstrapper from source path: $resolvedSourcePath"
        }

        $sourceLabel = if ($sourceItem.PSIsContainer) {
            "copied from host directory '$resolvedSourcePath'"
        }
        else {
            "copied from host path '$resolvedSourcePath'"
        }
        Write-InstallerHash -Path $InstallerPath -SourceLabel $sourceLabel
        return
    }

    if (Test-ValidFile -Path $InstallerPath) {
        $existingHash = Get-UpperInvariant -Value ((Get-FileHash -Algorithm SHA256 -LiteralPath $InstallerPath).Hash)
        $downloadHashMatch = (-not [string]::IsNullOrWhiteSpace($DownloadSha256)) -and ($existingHash -eq (Get-UpperInvariant -Value $DownloadSha256))
        if ((Test-HasNipmCompanionFiles -InstallerPath $InstallerPath) -or $downloadHashMatch) {
            Write-InstallerHash -Path $InstallerPath -SourceLabel 'existing local file'
            return
        }

        Write-Host 'Existing local install.exe found without NIPM companion files; refreshing from source.'
        Remove-Item -LiteralPath $InstallerPath -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($DownloadUrl)) {
        Write-Host "Attempting NIPM bootstrapper download from '$DownloadUrl'."
        try {
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath
            if (-not (Test-ValidFile -Path $InstallerPath)) {
                throw 'Downloaded file is missing or empty.'
            }

            if (-not [string]::IsNullOrWhiteSpace($DownloadSha256)) {
                $downloadedHash = Get-UpperInvariant -Value ((Get-FileHash -Algorithm SHA256 -LiteralPath $InstallerPath).Hash)
                $expectedHash = Get-UpperInvariant -Value $DownloadSha256
                if ($downloadedHash -ne $expectedHash) {
                    throw "Downloaded NIPM installer hash mismatch. Expected $expectedHash, got $downloadedHash."
                }
            }

            Write-InstallerHash -Path $InstallerPath -SourceLabel "downloaded from '$DownloadUrl'"
            return
        }
        catch {
            if (Test-Path -LiteralPath $InstallerPath) {
                Remove-Item -LiteralPath $InstallerPath -Force -ErrorAction SilentlyContinue
            }
            Write-Warning "NIPM download attempt failed: $($_.Exception.Message)"
        }
    }

    throw "Unable to locate a valid NIPM bootstrapper. Provide -NipmInstallerSourcePath or a working -NipmInstallerDownloadUrl."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$dockerfilePath = Join-Path $PSScriptRoot 'Dockerfile-windows'
$installerScriptPath = Join-Path $PSScriptRoot 'Resources\Windows Resources\Install-LV2020x64.ps1'
$installerBootstrapperPath = Join-Path $PSScriptRoot 'Resources\Windows Resources\install.exe'
$seedTag = Get-DerivedImageTag -BaseTag $ImageTag -Suffix 'seed'
if ([string]::IsNullOrWhiteSpace($Phase1Tag)) {
    $Phase1Tag = Get-DerivedImageTag -BaseTag $ImageTag -Suffix 'phase1'
}
if ([string]::IsNullOrWhiteSpace($Phase2Tag)) {
    $Phase2Tag = Get-DerivedImageTag -BaseTag $ImageTag -Suffix 'phase2'
}

$statusRoot = Join-Path $repoRoot 'builds\status'
Ensure-Directory -Path $statusRoot
$summaryTimestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
$summaryPath = Join-Path $statusRoot ("lv2020x64-build-summary-{0}.json" -f $summaryTimestamp)
$installSessionId = [Guid]::NewGuid().ToString()
$intermediatePhaseTags = New-Object System.Collections.Generic.List[string]
$phaseRecords = New-Object System.Collections.Generic.List[object]
$activePhaseContainer = ''
$currentImageTag = $seedTag
$buildOutcome = 'failed'
$buildErrorMessage = ''
$finalExitCode = 1
$finalSourceTag = ''
$lastCursor = ''
$lastStep = ''
$lastMandatoryPackage = ''
$lastCheckpointWasReboot = $false

Write-Host "Repo root: $repoRoot"
Write-Host "Final image tag: $ImageTag"
Write-Host "Base image: $BaseImage"
Write-Host "Volume: $PersistVolumeName"
Write-Host "Container DNS: $DnsServer"
Write-Host "NIPM download URL: $NipmInstallerDownloadUrl"
Write-Host "Max resume phases: $MaxResumePhases"

if (-not (Test-Path -Path $dockerfilePath)) {
    throw "Required file not found: $dockerfilePath"
}
if (-not (Test-Path -Path $installerScriptPath)) {
    throw "Required file not found: $installerScriptPath"
}

Ensure-NipmInstallerBootstrapper `
    -InstallerPath $installerBootstrapperPath `
    -DownloadUrl $NipmInstallerDownloadUrl `
    -DownloadSha256 $NipmInstallerDownloadSha256 `
    -SourcePath $NipmInstallerSourcePath

$branchName = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to determine the current git branch.'
}
if ($branchName -ne 'lv2020x64') {
    Write-Warning "Expected branch 'lv2020x64'; current branch is '$branchName'. Continuing."
}

$dockerServerOs = (& docker version --format '{{.Server.Os}}' 2>$null).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query Docker server mode. Ensure Docker Desktop is running.'
}
if ($dockerServerOs -ne 'windows') {
    throw "Docker server is not in Windows mode. Current server OS: $dockerServerOs"
}

& docker volume ls --filter ("name=^{0}$" -f $PersistVolumeName) --format '{{.Name}}' > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Unable to query Docker volumes. Ensure Docker Desktop is running and accessible."
}

$volumeExists = ((& docker volume ls --filter ("name=^{0}$" -f $PersistVolumeName) --format '{{.Name}}' 2>$null) | ForEach-Object { $_.Trim() }) -contains $PersistVolumeName
if (-not $volumeExists) {
    Invoke-DockerCommand -Arguments @('volume', 'create', $PersistVolumeName) -Description "create volume '$PersistVolumeName'" | Out-Null
}

try {
    $buildArgs = @(
        'build',
        '--file', $dockerfilePath,
        '--tag', $seedTag,
        '--build-arg', "DEFER_LV_INSTALL=1",
        '--build-arg', "BASE_IMAGE=$BaseImage",
        '--build-arg', "LV_YEAR=$LvYear",
        '--build-arg', "LV_FEED_LOCATION=$LvFeedLocation",
        '--build-arg', "LV_CORE_PACKAGE=$LvCorePackage",
        '--build-arg', "LV_CLI_PACKAGE=$LvCliPackage",
        '--build-arg', "LV_CLI_PORT=$LvCliPort",
        '--build-arg', "INSTALL_OPTIONAL_HELP=$InstallOptionalHelp",
        $PSScriptRoot
    )
    Invoke-DockerCommand -Arguments $buildArgs -Description 'build seed image' | Out-Null

    $volumeArg = '{0}:C:\lv-persist' -f $PersistVolumeName
    $completed = $false

    for ($phaseIndex = 1; $phaseIndex -le $MaxResumePhases; $phaseIndex++) {
        $phaseContainer = "lv2020x64-phase{0}-{1}" -f $phaseIndex, ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        $activePhaseContainer = $phaseContainer
        $phaseExitCode = -1
        $phaseTag = ''
        $phaseStateInfo = $null
        $phaseState = $null
        $phaseStuckCheckpoint = $false
        $phaseRecord = [ordered]@{
            phase_index = $phaseIndex
            source_image = $currentImageTag
            container_name = $phaseContainer
            exit_code = $null
            phase_tag = $null
            state_available = $false
            state_parse_ok = $false
            state_snapshot = $null
            state_raw = ''
            state_error = ''
            checkpoint = $false
            stuck_reboot_checkpoint = $false
        }

        try {
            $phaseArgs = @(
                'run',
                '--name', $phaseContainer,
                '--volume', $volumeArg
            )
            if (-not [string]::IsNullOrWhiteSpace($DnsServer)) {
                $phaseArgs += @('--dns', $DnsServer)
            }
            $phaseArgs += @(
                '--env', "LV_FEED_LOCATION=$LvFeedLocation",
                '--env', "LV_YEAR=$LvYear",
                '--env', "LV_CORE_PACKAGE=$LvCorePackage",
                '--env', "LV_CLI_PACKAGE=$LvCliPackage",
                '--env', "LV_CLI_PORT=$LvCliPort",
                '--env', "INSTALL_OPTIONAL_HELP=$InstallOptionalHelp",
                '--env', "LV_INSTALL_SESSION_ID=$installSessionId",
                $currentImageTag,
                'powershell',
                '-NoProfile',
                '-File', 'C:\ni\resources\Install-LV2020x64.ps1',
                '-PersistRoot', 'C:\lv-persist',
                '-SessionId', $installSessionId,
                '-PhaseIndex', [string]$phaseIndex
            )
            $phaseExitCode = Invoke-DockerCommand -Arguments $phaseArgs -Description ("phase{0} install" -f $phaseIndex) -AllowedExitCodes @(0, 194)
            $phaseRecord.exit_code = $phaseExitCode

            $phaseStateInfo = Get-InstallStateSnapshot -PersistVolume $PersistVolumeName -ReaderImage $BaseImage
            $phaseRecord.state_available = [bool]$phaseStateInfo.available
            $phaseRecord.state_parse_ok = [bool]$phaseStateInfo.parse_ok
            $phaseRecord.state_raw = [string]$phaseStateInfo.raw
            $phaseRecord.state_error = [string]$phaseStateInfo.error
            if ($phaseRecord.state_parse_ok) {
                $phaseState = $phaseStateInfo.parsed
                $phaseRecord.state_snapshot = $phaseState
            }

            if ($phaseExitCode -eq 194) {
                $phaseTag = Get-PhaseTag -PhaseIndex $phaseIndex
                $phaseRecord.phase_tag = $phaseTag
                $phaseRecord.checkpoint = $true
                Invoke-DockerCommand -Arguments @('commit', $phaseContainer, $phaseTag) -Description ("commit checkpoint phase{0} image" -f $phaseIndex) | Out-Null
                $intermediatePhaseTags.Add($phaseTag) | Out-Null

                $currentCursor = Get-StateField -StateObject $phaseState -FieldName 'resume_cursor'
                $currentStep = Get-StateField -StateObject $phaseState -FieldName 'step'
                $currentMandatoryPackage = Get-StateField -StateObject $phaseState -FieldName 'mandatory_package'

                if ($lastCheckpointWasReboot -and
                    $currentCursor -eq $lastCursor -and
                    $currentStep -eq $lastStep -and
                    $currentMandatoryPackage -eq $lastMandatoryPackage) {
                    $phaseStuckCheckpoint = $true
                    $phaseRecord.stuck_reboot_checkpoint = $true
                    $buildOutcome = 'stuck_reboot_checkpoint'
                    $finalExitCode = 194
                    $buildErrorMessage = ("Stuck reboot checkpoint detected at phase {0}. resume_cursor='{1}', step='{2}', mandatory_package='{3}'." -f $phaseIndex, $currentCursor, $currentStep, $currentMandatoryPackage)
                }

                $lastCursor = $currentCursor
                $lastStep = $currentStep
                $lastMandatoryPackage = $currentMandatoryPackage
                $lastCheckpointWasReboot = $true

                $currentImageTag = $phaseTag
            }
            elseif ($phaseExitCode -eq 0) {
                Invoke-DockerCommand -Arguments @('commit', $phaseContainer, $ImageTag) -Description ("commit final image from phase{0} container" -f $phaseIndex) | Out-Null
                $phaseRecord.phase_tag = $ImageTag
                $finalSourceTag = $currentImageTag
                $buildOutcome = 'completed'
                $finalExitCode = 0
                $completed = $true
                $lastCheckpointWasReboot = $false
            }
        }
        finally {
            $phaseRecords.Add([pscustomobject]$phaseRecord) | Out-Null
            if (-not $KeepIntermediate.IsPresent) {
                Remove-ContainerIfPresent -ContainerName $phaseContainer
            }
            $activePhaseContainer = ''
        }

        if ($phaseStuckCheckpoint) {
            break
        }
        if ($completed) {
            break
        }
    }

    if (-not $completed -and [string]::IsNullOrWhiteSpace($buildErrorMessage)) {
        if ($buildOutcome -eq 'stuck_reboot_checkpoint') {
            # buildErrorMessage already assigned by stuck checkpoint path.
        }
        elseif ($phaseRecords.Count -ge $MaxResumePhases) {
            $buildOutcome = 'max_resume_phases_exceeded'
            $finalExitCode = 194
            $buildErrorMessage = "Reached MaxResumePhases=$MaxResumePhases without completion."
        }
        else {
            $buildOutcome = 'failed'
            $finalExitCode = 1
            $buildErrorMessage = 'Resumable build ended without a successful completion state.'
        }
    }
}
catch {
    if ([string]::IsNullOrWhiteSpace($buildErrorMessage)) {
        $buildErrorMessage = $_.Exception.Message
    }
    if ($finalExitCode -eq 0) {
        $finalExitCode = 1
    }
    if ($buildOutcome -eq 'completed') {
        $buildOutcome = 'failed'
    }
}
finally {
    if (-not $KeepIntermediate.IsPresent) {
        if (-not [string]::IsNullOrWhiteSpace($activePhaseContainer)) {
            Remove-ContainerIfPresent -ContainerName $activePhaseContainer
        }
        Remove-ImageIfPresent -Tag $seedTag
        foreach ($tag in $intermediatePhaseTags) {
            Remove-ImageIfPresent -Tag $tag
        }
    }

    $summary = [ordered]@{
        schema_version = '1.0'
        generated_utc = (Get-Date).ToUniversalTime().ToString('o')
        repo_root = $repoRoot
        image_tag = $ImageTag
        final_source_tag = $finalSourceTag
        base_image = $BaseImage
        persist_volume = $PersistVolumeName
        dns_server = $DnsServer
        max_resume_phases = $MaxResumePhases
        keep_intermediate = $KeepIntermediate.IsPresent
        install_session_id = $installSessionId
        lv_year = $LvYear
        lv_core_package = $LvCorePackage
        lv_cli_package = $LvCliPackage
        lv_cli_port = $LvCliPort
        build_outcome = $buildOutcome
        final_exit_code = $finalExitCode
        error_message = $buildErrorMessage
        summary_path = $summaryPath
        phase_count = $phaseRecords.Count
        phases = $phaseRecords
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $summaryPath -Encoding utf8
    Write-Host "build_summary_path=$summaryPath"
}

if ($finalExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($buildErrorMessage)) {
    if ([string]::IsNullOrWhiteSpace($buildErrorMessage)) {
        $buildErrorMessage = "Resumable build failed with outcome '$buildOutcome'. See summary at $summaryPath"
    }
    throw $buildErrorMessage
}

Write-Host "Resumable build completed successfully. Final image: $ImageTag"
