# Building Your Own LabVIEW Windows Container Image

This guide covers the `lv2020x64` Windows custom-image workflow in this fork.
It includes a resumable build path for installs that return reboot-required
(`Error -125071`).

Use this approach if you need to:

- Iterate locally with LabVIEW 2020 x64 and LabVIEWCLI.
- Avoid repeating full install work when NI Package Manager requests restart.
- Keep image build inputs explicit and reproducible.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Default lv2020x64 Contract](#default-lv2020x64-contract)
- [Fast Path: Dockerfile-Only Build](#fast-path-dockerfile-only-build)
- [Restart-Aware Path (Recommended for -125071)](#restart-aware-path-recommended-for--125071)
- [Troubleshooting Reboot-Required Installs](#troubleshooting-reboot-required-installs)
- [Engineered Prompt Template (lv2020x64)](#engineered-prompt-template-lv2020x64)
- [Final Notes](#final-notes)

## Prerequisites

Before building your own Windows image, make sure you have:

- A Windows host with Docker configured for **Windows containers**.
- Internet access from host and container to `download.ni.com`.
- Access to NI Package Manager (NIPKG) feeds and installers.
- This fork's workflow files:
  `examples/build-your-own-image/Dockerfile-windows`
- `examples/build-your-own-image/Resources/Windows Resources/Install-LV2020x64.ps1`
- `examples/build-your-own-image/build-windows-lv2020x64-resumable.ps1`

## Default lv2020x64 Contract

`examples/build-your-own-image/Dockerfile-windows` defaults to:

```dockerfile
ARG LV_YEAR=2020
ARG LV_FEED_LOCATION=
ARG LV_CORE_PACKAGE=ni-labview-2020-core-en
ARG LV_CLI_PACKAGE=ni-labview-command-line-interface-x86
ARG LV_CLI_PORT=3366
ARG INSTALL_OPTIONAL_HELP=0
ARG DEFER_LV_INSTALL=0
```

Key behavior:

- `LV_FEED_LOCATION` is required when `DEFER_LV_INSTALL=0`.
- Mandatory packages fail hard when package IDs are invalid.
- `INSTALL_OPTIONAL_HELP=0` skips optional help package install.
- `LV_CLI_PORT` is applied to:
  `LabVIEW.ini` (`server.tcp.port`) and
  `LabVIEWCLI.ini` (`DefaultPortNumber`).
- `DEFER_LV_INSTALL=1` builds a seed image without LV package install.

## Fast Path: Dockerfile-Only Build

Use this when install completes in one pass (no reboot checkpoint):

```powershell
cd .\examples\build-your-own-image

$lvFeed = 'https://download.ni.com/support/nipkg/products/ni-l/' +
  'ni-labview-2020/20.0/released'

docker build -t labview-custom-windows:2020q1-windows -f Dockerfile-windows `
  --build-arg LV_FEED_LOCATION=$lvFeed `
  --build-arg LV_CLI_PORT=3366 `
  --build-arg INSTALL_OPTIONAL_HELP=0
```

If the build succeeds, verify image presence:

```powershell
docker images
```

## Restart-Aware Path (Recommended for -125071)

Use this path when NIPKG reports reboot-required (`Error -125071`).
This flow persists checkpoint state in a Docker volume and resumes in phase 2.

Script:

- `examples/build-your-own-image/build-windows-lv2020x64-resumable.ps1`

Parameters:

- `-ImageTag` default `labview-custom-windows:2020q1-windows`
- `-LvFeedLocation` required
- `-PersistVolumeName` default `vm`
- `-DnsServer` default `1.1.1.1`
- `-NipmInstallerDownloadUrl` default
  `https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager26.0.0.exe`
- `-NipmInstallerDownloadSha256` default
  `A2AF381482F85ABA2A963676EAC436F96D69572A9EBFBAF85FF26C372A1995C3`
- `-NipmInstallerSourcePath` optional host file override
- `-Phase1Tag` and `-Phase2Tag` optional overrides
- `-KeepIntermediate` optional switch

Run:

```powershell
cd .\examples\build-your-own-image

$lvFeed = 'https://download.ni.com/support/nipkg/products/ni-l/' +
  'ni-labview-2020/20.0/released'

pwsh -NoProfile -File .\build-windows-lv2020x64-resumable.ps1 `
  -LvFeedLocation $lvFeed `
  -PersistVolumeName vm
```

What the script does:

1. Validates branch is `lv2020x64`.
1. Verifies Docker is in Windows container mode.
1. Ensures
   `examples/build-your-own-image/Resources/Windows Resources/install.exe`
   exists by using the first valid source:
   - existing local file
   - `-NipmInstallerSourcePath` (if supplied)
   - download from `-NipmInstallerDownloadUrl`
1. Prints SHA256 for the installer file used.
1. Ensures the named volume exists (creates it when missing).
1. Uses `--dns` for phase containers (default `1.1.1.1`).
1. Builds a seed image with `DEFER_LV_INSTALL=1`.
1. Runs phase 1 install in a container with `-v vm:C:\lv-persist`.
1. If phase 1 exits `194`, commits phase 1 and resumes phase 2.
1. Commits and tags the final image on success.

Checkpoint artifacts written to the volume:

- `C:\lv-persist\state.json`
- `C:\lv-persist\install.log`

## Troubleshooting Reboot-Required Installs

### Error `-125071` During Install

If you see:

- `Error -125071: A system reboot is needed to complete the transaction.`

Actions:

1. Use the resumable script instead of Dockerfile-only build.
1. Keep `-PersistVolumeName vm` so state survives phase transitions.
1. Inspect checkpoint state:

```powershell
docker run --rm -v vm:C:\lv-persist mcr.microsoft.com/windows/server:ltsc2022 `
  powershell -NoProfile -Command "Get-Content C:\lv-persist\state.json"
```

1. If phase 2 still exits `194`, rerun with `-KeepIntermediate` and inspect
   logs before retrying.

### Missing Feed Location

If build fails with missing feed location:

- Pass `--build-arg LV_FEED_LOCATION=<feed-url>` for Dockerfile-only.
- Pass `-LvFeedLocation <feed-url>` for the resumable script.
- Recommended value for this 2020 scope:
  `https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2020/20.0/released`
- Do not use local raw metadata folders such as
  `C:\ProgramData\National Instruments\NI Package Manager\raw\...` as a direct
  `feed-add` source; they are not valid feed URIs for this workflow.

### Missing Installer Bootstrapper

If build fails before seed image creation due to a missing installer bootstrapper:

1. Rerun with explicit download URL/SHA overrides when needed:

```powershell
$nipmUrl = 'https://download.ni.com/support/nipkg/products/' +
  'ni-package-manager/' +
  'installers/NIPackageManager26.0.0.exe'
$nipmSha256 = 'A2AF381482F85ABA2A963676EAC436F96D69572A9EBFBAF85FF26C372A1995C3'

pwsh -NoProfile -File .\build-windows-lv2020x64-resumable.ps1 `
  -LvFeedLocation $lvFeed `
  -NipmInstallerDownloadUrl $nipmUrl `
  -NipmInstallerDownloadSha256 $nipmSha256 `
  -PersistVolumeName vm
```

1. If download is unavailable, pass a host file directly:

```powershell
pwsh -NoProfile -File .\build-windows-lv2020x64-resumable.ps1 `
  -LvFeedLocation $lvFeed `
  -NipmInstallerSourcePath "D:\Installers\NIPM\install.exe" `
  -PersistVolumeName vm
```

1. If the container cannot resolve `download.ni.com`, set a reachable DNS server:

```powershell
pwsh -NoProfile -File .\build-windows-lv2020x64-resumable.ps1 `
  -LvFeedLocation $lvFeed `
  -DnsServer 1.1.1.1 `
  -PersistVolumeName vm
```

### Port Contract Mismatch

If CLI cannot connect:

1. Confirm build arg `LV_CLI_PORT`.
1. Verify final in-image files:
   - `C:\Program Files\National Instruments\LabVIEW 2020\LabVIEW.ini`
   - `C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini`

## Engineered Prompt Template (lv2020x64)

Use this prompt to ask an AI assistant for reproducible updates:

```text
You are editing a fork at path `labview-for-containers-fork`
on branch `lv2020x64`.

Goal:
- Produce a deterministic local Windows image for LabVIEW 2020 x64 + LabVIEWCLI.
- Optimize for iterative local development speed.
- Support resumable install when NIPKG reports reboot-required (`Error -125071`).

Hard requirements:
1) Keep these defaults:
   - LV_YEAR=2020
   - LV_CORE_PACKAGE=ni-labview-2020-core-en
   - LV_CLI_PACKAGE=ni-labview-command-line-interface-x86
   - LV_CLI_PORT=3366
   - INSTALL_OPTIONAL_HELP=0
2) Treat LV_FEED_LOCATION as required for non-deferred install paths.
3) Mandatory packages must fail hard if package IDs are invalid.
4) Update both LabVIEW.ini and LabVIEWCLI.ini port settings from LV_CLI_PORT.
5) Keep a resumable flow that uses Docker volume `vm` (overridable)
   and exits 194 for reboot checkpoints.
6) Preserve and extend existing unstaged edits; do not discard them.

Expected outputs:
- Updated Dockerfile-windows.
- Updated/reusable resumable host script.
- Updated in-container installer script.
- Updated docs with fast path + restart-aware path + troubleshooting.
- Validation commands to syntax-check PowerShell and verify doc commands.
```

## Final Notes

1. Windows container images run only on Windows hosts in Windows mode.
1. All LabVIEW operations in these containers should use `LabVIEWCLI`.
1. `examples/integration-into-cicd/runlabview.ps1` now defaults to `2020`.
1. If you change package IDs or args, retag resulting images for traceability.
1. For additional headless guidance, see:
   - [Windows Prebuilt Images](./windows-prebuilt.md)
   - [Headless LabVIEW](./headless-labview.md)
