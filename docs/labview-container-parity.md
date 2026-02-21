# Dedicated Validation Host Policy

This repository can run on hosted lanes and on a dedicated self-hosted Windows
validation host. When using a dedicated host, enforce this contract:

- Installed LabVIEW matrix:
  - `2020 x64`
  - `2020 x86`
  - `2026 x64`
  - `2026 x86`
- CLI policy:
  - `LabVIEWCLI` resolved from `PATH` must be major `26`.
- Port policy:
  - `2020/64 -> 3366`
  - `2020/32 -> 3365`
  - `2026/64 -> 3363`
  - `2026/32 -> 3364`
- Targeting policy:
  - Always use explicit `LabVIEWPath` and `PortNumber` for operations.
  - Never infer target year from the CLI binary version.

Contract files:

- `Tooling/runner-host-contract.json`
- `Tooling/labviewcli-port-contract.json`

## Install Order Standard

Install in this order on dedicated validation hosts:

1. `LabVIEW 2020 (64-bit)`
1. `LabVIEW 2020 (32-bit)`
1. `LabVIEW 2026 (64-bit)`
1. `LabVIEW 2026 (32-bit)`

Reboot whenever NI installers request it.

## Host Baseline Snapshot

Run before NI repair/reinstall or runner reconfiguration:

```powershell
$ErrorActionPreference = 'Stop'
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$statusRoot = Join-Path (Resolve-Path .).Path 'builds/status'
New-Item -Path $statusRoot -ItemType Directory -Force | Out-Null

$baselinePath = Join-Path $statusRoot ("host-baseline-{0}.json" -f $timestamp)
$rollbackPath = Join-Path $statusRoot ("host-rollback-notes-{0}.txt" -f $timestamp)

$cli = Get-Command LabVIEWCLI -ErrorAction SilentlyContinue
$cliPath = if ($cli) { $cli.Source } else { $null }
$cliMajor = if ($cliPath -and (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
  (Get-Item -LiteralPath $cliPath).VersionInfo.FileMajorPart
} else {
  $null
}

$iniPaths = @(
  "C:\Program Files\National Instruments\LabVIEW 2020\LabVIEW.ini",
  "C:\Program Files (x86)\National Instruments\LabVIEW 2020\LabVIEW.ini",
  "C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.ini",
  "C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.ini"
)

$iniState = foreach ($ini in $iniPaths) {
  if (Test-Path -LiteralPath $ini -PathType Leaf) {
    $lines = Get-Content -LiteralPath $ini
    [pscustomobject]@{
      path = $ini
      server_tcp_enabled = ($lines | Select-String -Pattern '^\s*server\.tcp\.enabled\s*=.*$').Line
      server_tcp_port = ($lines | Select-String -Pattern '^\s*server\.tcp\.port\s*=.*$').Line
    }
  } else {
    [pscustomobject]@{
      path = $ini
      missing = $true
    }
  }
}

$baseline = [ordered]@{
  timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
  os_build = [System.Environment]::OSVersion.VersionString
  docker_server_os = (docker version --format '{{.Server.Os}}' 2>$null)
  docker_version = (docker version --format '{{json .}}' 2>$null)
  labviewcli_path = $cliPath
  labviewcli_major = $cliMajor
  install_roots = @(
    "C:\Program Files\National Instruments\LabVIEW 2020",
    "C:\Program Files (x86)\National Instruments\LabVIEW 2020",
    "C:\Program Files\National Instruments\LabVIEW 2026",
    "C:\Program Files (x86)\National Instruments\LabVIEW 2026"
  )
  ini_contract_state = $iniState
}

$baseline | ConvertTo-Json -Depth 8 | Out-File -FilePath $baselinePath -Encoding utf8
@(
  "Host rollback notes",
  "Baseline artifact: $baselinePath",
  "Record PATH and NI-related machine changes for rollback here."
) | Set-Content -Path $rollbackPath -Encoding utf8
```

## Dedicated Host Contract Check

Run manually:

```powershell
pwsh -NoProfile -File .\Tooling\Check-Runner.ps1 `
  -RepoRoot . `
  -EnforceHostContract `
  -HostContractPath Tooling/runner-host-contract.json `
  -RequiredLabVIEWYears 2020,2026 `
  -RequiredCliMajor 26
```

Expected output:

- Pass/fail on the runner contract.
- Summary JSON:
  - `builds/status/check-runner-host-contract-<timestamp>.json`

## Workflow Wiring

Self-hosted lane in `.github/workflows/labview-2020-stabilization-matrix.yml`
enables this policy with:

- `LVIE_ENFORCE_DEDICATED_HOST_CONTRACT=1`
- `LVIE_REQUIRED_LABVIEW_YEARS=2020,2026`
- `LVIE_REQUIRED_CLI_MAJOR=26`

Hosted lanes are intentionally unchanged.

## Monthly Audit Rule

At least monthly (and always after NI repair/reinstall):

1. Run dedicated host contract check command.
1. Archive new `check-runner-host-contract-*.json` under validation evidence.
1. Do not execute self-hosted stabilization lanes until the contract check is
   green.
