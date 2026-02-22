# Windows Custom Images Operations (Fork)

This runbook contains fork-specific operational workflows for Windows custom
images and certification.
It complements the canonical guide in
[Building Your Own LabVIEW Windows Container Image](./windows-custom-images.md).

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
- [Confirm Baseline with Built-In MassCompile (No Clone)](#confirm-baseline-with-built-in-masscompile-no-clone)
- [Troubleshooting Reboot-Required Installs](#troubleshooting-reboot-required-installs)
- [Phase 3 Local PPL From Known Image](#phase-3-local-ppl-from-known-image)
- [Troubleshooting Phase 3 PPL Builds](#troubleshooting-phase-3-ppl-builds)
- [Split-Track Execution (2026 Throughput + 2020 Stabilization)](#split-track-execution-2026-throughput--2020-stabilization)
- [Dedicated Validation Host Policy](#dedicated-validation-host-policy)
- [Image Contract Certification](#image-contract-certification)
- [2020 Promotion Freeze and Gate (Deferred)](#2020-promotion-freeze-and-gate-deferred)
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
ARG LV_CLI_PORT=3363
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
  --build-arg LV_CLI_PORT=3363 `
  --build-arg INSTALL_OPTIONAL_HELP=0
```

If the build succeeds, verify image presence:

```powershell
docker images
```

## Restart-Aware Path (Recommended for -125071)

Use this path when NIPKG reports reboot-required (`Error -125071`).
This flow persists checkpoint state in a Docker volume and resumes through a
phase loop (`phase1..phaseN`) until completion or checkpoint failure.

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
- `-MaxResumePhases` default `4`

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
1. Runs install in `phase1..phaseN` containers with `-v vm:C:\lv-persist`.
1. On each `194`, commits a checkpoint image `...-phase<index>` and resumes.
1. Detects stuck reboot checkpoints when consecutive phases return `194` with
   unchanged `resume_cursor` and package step.
1. Stops at success (`0`) or when `-MaxResumePhases` is exceeded.
1. Writes build summary JSON to `builds/status/lv2020x64-build-summary-*.json`.
1. Enforces `LV_CLI_PORT=3363`; other values fail fast.

## Confirm Baseline with Built-In MassCompile (No Clone)

Use this check to verify image baseline behavior without mounting external repos.

```powershell
docker run --rm labview-custom-windows:2020q1-windows `
  powershell -NoProfile -Command `
  "LabVIEWCLI -LabVIEWPath 'C:\Program Files\National Instruments\LabVIEW 2020\LabVIEW.exe' -OperationName MassCompile -DirectoryToCompile 'C:\Program Files\National Instruments\LabVIEW 2020\examples\Arrays' -PortNumber 3363 -Headless"
```

Expected result:

- Command exits `0`.
- No `-350000` in output.

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
   `builds/status/lv2020x64-build-summary-*.json` for checkpoint cursor and
   outcome classification before retrying.

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


## Phase 3 Local PPL From Known Image

Use this path to build `lv_icon.lvlibp` from an already-built x64 image.

Script:

- `examples/build-your-own-image/build-lv-icon-ppl-from-image.ps1`

Inputs:

- `-ImageTag` default `labview-custom-windows:2020q1-windows-phase2`
- `-IconEditorRepoRoot` optional; auto-resolves sibling icon-editor repo
- `-LvYear` default `2020`
- `-LvCliPort` default `3363`
- `-BuildSpecName` default `Editor Packed Library`
- `-OutputRelativePath` default `resource/plugins/lv_icon.lvlibp`
- `-KeepContainer` optional switch
- `-LogRoot` optional override for log output root

Happy path:

```powershell
cd .\examples\build-your-own-image

pwsh -NoProfile -File .\build-lv-icon-ppl-from-image.ps1 `
  -ImageTag labview-custom-windows:2020q1-windows-phase2
```

Debug path (keep failed container):

```powershell
pwsh -NoProfile -File .\build-lv-icon-ppl-from-image.ps1 `
  -ImageTag labview-custom-windows:2020q1-windows-phase2 `
  -KeepContainer
```

Expected outputs:

- PPL artifact: `<icon-editor-root>\resource\plugins\lv_icon.lvlibp`
- Logs: `TestResults\agent-logs\ppl-phase3-<timestamp>\`
- Summary: `summary.json` inside the run log folder

## Troubleshooting Phase 3 PPL Builds

### `-350000` LabVIEWCLI Connection Failure

If you see CLI connection failures:

1. Open run summary/logs under `TestResults\agent-logs\ppl-phase3-<timestamp>\`.
1. Check `phase3-diag\port-listening.txt` and `phase3-diag\netstat-ano.txt`.
1. Verify copied INI files under `phase3-diag\LabVIEW.ini` and `phase3-diag\LabVIEWCLI.ini`.
1. Re-run with `-KeepContainer` to preserve state for manual inspection.

### Missing Artifact With Zero-Like CLI Output

If `ExecuteBuildSpec` appears to run but output is missing:

1. Confirm `BuildSpecName` matches the project build spec.
1. Confirm `OutputRelativePath` matches expected output location.
1. Review `executebuildspec.log` and `collect-diagnostics.log` in the same run folder.

## Split-Track Execution (2026 Throughput + 2020 Stabilization)

Use this fork's split-track policy:

- Throughput track: run Phase 3 artifact production against
  `nationalinstruments/labview:2026q1-windows`.
- Stabilization track: isolate LabVIEW 2020 diagnostics in a separate manual workflow.
- Do not retag/publish `labview-custom-windows:2020q1-windows` in this pass.

Local 2026 throughput wrapper:

- `examples/build-your-own-image/run-phase3-throughput-2026.ps1`

Wrapper contract:

- `-IconEditorRepoRoot`
- `-OutputRelativePath`
- `-LvCliPort` (must be `3363`)
- `-KeepContainer`
- `-LogRoot`

Run two consecutive executions (required for local repeatability):

```powershell
cd .\examples\build-your-own-image

$iconRepo = 'D:\workspace\labview-icon-editor\labview-icon-editor'

pwsh -NoProfile -File .\run-phase3-throughput-2026.ps1 `
  -IconEditorRepoRoot $iconRepo

pwsh -NoProfile -File .\run-phase3-throughput-2026.ps1 `
  -IconEditorRepoRoot $iconRepo
```

Success criteria:

- both runs exit `0`
- both runs produce non-empty `resource\plugins\lv_icon.lvlibp`
- each run writes a `summary.json` under
  `TestResults\agent-logs\phase3-throughput-2026-<timestamp>\ppl-phase3-<timestamp>\`

Conservative cleanup after runs:

```powershell
pwsh -NoProfile -File .\cleanup-windows-docker-artifacts.ps1 `
  -Mode Conservative -Apply
```

Manual 2020 stabilization workflow:

- `.github/workflows/labview-2020-stabilization-matrix.yml`

Workflow inputs:

- `image_tag`
- `lv_year`
- `lv_cli_port`
- `runner_target`
- `base_matrix`
- `isolation_mode`
- `max_cli_attempts`

Stabilization outcomes:

- `pass`
- `port_not_listening`
- `cli_connect_fail`
- `environment_incompatible`

Each run uploads a diagnostic artifact bundle containing `summary.json`,
MassCompile logs, `lvtemporary_*`, netstat/process snapshots, and INI copies.

## Dedicated Validation Host Policy

For dedicated self-hosted Windows validation machines, use the host policy and
enforcement runbook in:

- `docs/labview-container-parity.md`

Key rule: do not infer target year from the `LabVIEWCLI` binary version.
Always pass explicit `LabVIEWPath` and `PortNumber` for operations.

## Image Contract Certification

Use this dedicated certification surface to produce machine-readable image
contract evidence:

- Profiles: `Tooling/image-contract-profiles.json`
- Summary schema: `Tooling/image-cert-summary.schema.json`
- Script: `examples/build-your-own-image/certify-image-contract.ps1`
- Workflow: `.github/workflows/labview-image-contract-certification.yml`

Certification runs aggregate repeated verifier passes and emit:

- `builds/status/image-contract-cert-summary-*.json`
- per-run diagnostics in `TestResults/agent-logs/certification-*`

Manual workflow inputs:

- `contract_profile`
- `image_tag`
- `runner_target`
- `isolation_mode`
- `max_cli_attempts`
- `repeat_runs`

For `2020-x64-stabilization`, certification may run on hosted lanes for
diagnostics, but `promotion_eligible` remains `false` unless runner
fingerprint indicates a real Server 2019 lane.

Comparison procedure (triage discipline):

1. Open previous failing references (`22262096511`, `22262277660`, `22262448572`).
1. Compare classification and verifier metrics against latest
   `image-contract-cert-summary-*.json`.
1. Confirm whether failure is `port_not_listening`, `cli_connect_fail`, or
   `environment_incompatible` before changing install/runtime settings.

## 2020 Promotion Freeze and Gate (Deferred)

Promotion remains blocked for `labview-custom-windows:2020q1-windows` until
one real Server 2019 lane passes two fresh runs with all of:

- `final_exit_code=0`
- `contains_minus_350000=false`
- `port_listening_before_cli=true`
- `promotion_eligible=true` in certification summary

Only after that gate:

1. create a backup tag for the current canonical image
1. retag validated candidate to `labview-custom-windows:2020q1-windows`

If any gate fails, keep candidate tags only and continue stabilization without
retagging canonical.

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
   - LV_CLI_PORT=3363
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
