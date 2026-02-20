[CmdletBinding()]
param(
    [string]$ImageTag = 'labview-custom-windows:2020q1-windows',
    [Parameter(Mandatory = $true)][string]$LvFeedLocation,
    [string]$PersistVolumeName = 'vm',
    [string]$Phase1Tag = '',
    [string]$Phase2Tag = '',
    [switch]$KeepIntermediate,
    [string]$LvYear = '2020',
    [string]$LvCorePackage = 'ni-labview-2020-core-en',
    [string]$LvCliPackage = 'ni-labview-command-line-interface-x86',
    [string]$LvCliPort = '3366',
    [ValidateSet('0', '1')][string]$InstallOptionalHelp = '0',
    [string]$DnsServer = '1.1.1.1',
    [string]$NipmInstallerDownloadUrl = 'https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager26.0.0.exe',
    [string]$NipmInstallerDownloadSha256 = 'A2AF381482F85ABA2A963676EAC436F96D69572A9EBFBAF85FF26C372A1995C3',
    [string]$NipmInstallerSourcePath = ''
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

$phase1Container = "lv2020x64-phase1-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$phase2Container = "lv2020x64-phase2-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$phase1Created = $false
$phase2Created = $false
$phase1TagCreated = $false
$phase2TagCreated = $false

Write-Host "Repo root: $repoRoot"
Write-Host "Final image tag: $ImageTag"
Write-Host "Volume: $PersistVolumeName"
Write-Host "Container DNS: $DnsServer"
Write-Host "NIPM download URL: $NipmInstallerDownloadUrl"

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
    Write-Warning 'Unable to determine the current git branch. Continuing without branch enforcement.'
}
elseif ($branchName -ne 'lv2020x64') {
    Write-Warning "Recommended branch is 'lv2020x64'. Continuing on '$branchName'."
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
        '--volume', $volumeArg
    )
    if (-not [string]::IsNullOrWhiteSpace($DnsServer)) {
        $phase1Args += @('--dns', $DnsServer)
    }
    $phase1Args += @(
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
            '--volume', $volumeArg
        )
        if (-not [string]::IsNullOrWhiteSpace($DnsServer)) {
            $phase2Args += @('--dns', $DnsServer)
        }
        $phase2Args += @(
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

        Invoke-DockerCommand -Arguments @('commit', $phase2Container, $Phase2Tag) -Description 'commit phase2 image' | Out-Null
        $phase2TagCreated = $true
        Invoke-DockerCommand -Arguments @('tag', $Phase2Tag, $ImageTag) -Description 'tag final image from phase2 image' | Out-Null
        Remove-ContainerIfPresent -ContainerName $phase2Container
        $phase2Created = $false
    }
    elseif ($phase1ExitCode -eq 0) {
        Invoke-DockerCommand -Arguments @('commit', $phase1Container, $Phase1Tag) -Description 'commit phase1 image' | Out-Null
        $phase1TagCreated = $true
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
