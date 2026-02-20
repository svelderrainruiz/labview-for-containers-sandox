[CmdletBinding()]
param(
    [string]$ImageTag = 'labview-custom-windows:lv2020x64',
    [Parameter(Mandatory = $true)][string]$LvFeedLocation,
    [string]$PersistVolumeName = 'vm',
    [string]$Phase1Tag = '',
    [string]$Phase2Tag = '',
    [switch]$KeepIntermediate,
    [string]$LvYear = '2020',
    [string]$LvCorePackage = 'ni-labview-2020-core-en',
    [string]$LvCliPackage = 'ni-labview-command-line-interface-x86',
    [string]$LvCliPort = '3366',
    [ValidateSet('0', '1')][string]$InstallOptionalHelp = '0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$dockerfilePath = Join-Path $PSScriptRoot 'Dockerfile-windows'
$installerScriptPath = Join-Path $PSScriptRoot 'Resources\Windows Resources\Install-LV2020x64.ps1'
$seedTag = Get-DerivedImageTag -BaseTag $ImageTag -Suffix 'seed'
if ([string]::IsNullOrWhiteSpace($Phase1Tag)) {
    $Phase1Tag = Get-DerivedImageTag -BaseTag $ImageTag -Suffix 'phase1'
}
if ([string]::IsNullOrWhiteSpace($Phase2Tag)) {
    $Phase2Tag = Get-DerivedImageTag -BaseTag $ImageTag -Suffix 'phase2'
}

$phase1Container = "lv2020x64-phase1-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$phase2Container = "lv2020x64-phase2-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$phase1Created = $false
$phase2Created = $false
$phase1TagCreated = $false
$phase2TagCreated = $false

Write-Host "Repo root: $repoRoot"
Write-Host "Final image tag: $ImageTag"
Write-Host "Volume: $PersistVolumeName"

if (-not (Test-Path -Path $dockerfilePath)) {
    throw "Required file not found: $dockerfilePath"
}
if (-not (Test-Path -Path $installerScriptPath)) {
    throw "Required file not found: $installerScriptPath"
}

$branchName = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to determine the current git branch.'
}
if ($branchName -ne 'lv2020x64') {
    throw "This script must run on branch 'lv2020x64'. Current branch: $branchName"
}

$dockerServerOs = (& docker version --format '{{.Server.Os}}' 2>$null).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query Docker server mode. Ensure Docker Desktop is running.'
}
if ($dockerServerOs -ne 'windows') {
    throw "Docker server is not in Windows mode. Current server OS: $dockerServerOs"
}

& docker volume inspect $PersistVolumeName *> $null
if ($LASTEXITCODE -ne 0) {
    Invoke-DockerCommand -Arguments @('volume', 'create', $PersistVolumeName) -Description "create volume '$PersistVolumeName'" | Out-Null
}

try {
    $buildArgs = @(
        'build',
        '--file', $dockerfilePath,
        '--tag', $seedTag,
        '--build-arg', "DEFER_LV_INSTALL=1",
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
    $phase1Args = @(
        'run',
        '--name', $phase1Container,
        '--volume', $volumeArg,
        '--env', "LV_FEED_LOCATION=$LvFeedLocation",
        '--env', "LV_YEAR=$LvYear",
        '--env', "LV_CORE_PACKAGE=$LvCorePackage",
        '--env', "LV_CLI_PACKAGE=$LvCliPackage",
        '--env', "LV_CLI_PORT=$LvCliPort",
        '--env', "INSTALL_OPTIONAL_HELP=$InstallOptionalHelp",
        $seedTag,
        'powershell',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', 'C:\ni\resources\Install-LV2020x64.ps1',
        '-PersistRoot', 'C:\lv-persist'
    )
    $phase1ExitCode = Invoke-DockerCommand -Arguments $phase1Args -Description 'phase1 install' -AllowedExitCodes @(0, 194)
    $phase1Created = $true

    if ($phase1ExitCode -eq 194) {
        Write-Host 'Phase 1 reached reboot-required checkpoint; committing phase1 image.'
        Invoke-DockerCommand -Arguments @('commit', $phase1Container, $Phase1Tag) -Description 'commit phase1 image' | Out-Null
        $phase1TagCreated = $true
        Remove-ContainerIfPresent -ContainerName $phase1Container
        $phase1Created = $false

        $phase2Args = @(
            'run',
            '--name', $phase2Container,
            '--volume', $volumeArg,
            '--env', "LV_FEED_LOCATION=$LvFeedLocation",
            '--env', "LV_YEAR=$LvYear",
            '--env', "LV_CORE_PACKAGE=$LvCorePackage",
            '--env', "LV_CLI_PACKAGE=$LvCliPackage",
            '--env', "LV_CLI_PORT=$LvCliPort",
            '--env', "INSTALL_OPTIONAL_HELP=$InstallOptionalHelp",
            $Phase1Tag,
            'powershell',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', 'C:\ni\resources\Install-LV2020x64.ps1',
            '-PersistRoot', 'C:\lv-persist'
        )
        $phase2ExitCode = Invoke-DockerCommand -Arguments $phase2Args -Description 'phase2 install' -AllowedExitCodes @(0, 194)
        $phase2Created = $true

        if ($phase2ExitCode -eq 194) {
            throw "Phase 2 still requires reboot. Inspect '$PersistVolumeName\\state.json' and container logs."
        }

        Invoke-DockerCommand -Arguments @('exec', $phase2Container, 'cmd', '/S', '/C', 'if exist C:\ni\resources rmdir /S /Q C:\ni\resources') -Description 'cleanup resources in phase2 container' | Out-Null
        Invoke-DockerCommand -Arguments @('commit', $phase2Container, $Phase2Tag) -Description 'commit phase2 image' | Out-Null
        $phase2TagCreated = $true
        Invoke-DockerCommand -Arguments @('tag', $Phase2Tag, $ImageTag) -Description 'tag final image from phase2 image' | Out-Null
        Remove-ContainerIfPresent -ContainerName $phase2Container
        $phase2Created = $false
    }
    elseif ($phase1ExitCode -eq 0) {
        Invoke-DockerCommand -Arguments @('commit', $phase1Container, $Phase1Tag) -Description 'commit phase1 image' | Out-Null
        $phase1TagCreated = $true
        Invoke-DockerCommand -Arguments @('exec', $phase1Container, 'cmd', '/S', '/C', 'if exist C:\ni\resources rmdir /S /Q C:\ni\resources') -Description 'cleanup resources in phase1 container' | Out-Null
        Invoke-DockerCommand -Arguments @('commit', $phase1Container, $ImageTag) -Description 'commit final image from phase1 container' | Out-Null
        Remove-ContainerIfPresent -ContainerName $phase1Container
        $phase1Created = $false
    }
    else {
        throw "Unexpected phase1 exit code: $phase1ExitCode"
    }

    if (-not $KeepIntermediate.IsPresent) {
        Remove-ImageIfPresent -Tag $seedTag
        if ($phase1TagCreated) {
            Remove-ImageIfPresent -Tag $Phase1Tag
        }
        if ($phase2TagCreated) {
            Remove-ImageIfPresent -Tag $Phase2Tag
        }
    }

    Write-Host "Resumable build completed successfully. Final image: $ImageTag"
}
finally {
    if (-not $KeepIntermediate.IsPresent) {
        if ($phase1Created) {
            Remove-ContainerIfPresent -ContainerName $phase1Container
        }
        if ($phase2Created) {
            Remove-ContainerIfPresent -ContainerName $phase2Container
        }
    }
}
