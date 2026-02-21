# Agent Operating Contract

## Scope
These instructions apply to this repository (`labview-for-containers`) and define how coding agents should execute changes, run validation, and publish evidence.

## Intent
- Keep delivery moving on deterministic green paths.
- Stabilize risky lanes without contaminating canonical image tags.
- Prefer auditable, machine-readable evidence over ad-hoc conclusions.

## Safety and Worktree Discipline
- Do not run destructive git commands (`reset --hard`, `checkout --`) unless explicitly requested.
- If the active worktree is dirty, create an isolated worktree for merge/integration tasks.
- Do not delete prior diagnostics under `TestResults/agent-logs` unless explicitly requested.
- Keep each branch focused on one concern (for example, certification workflow logic vs docs).

## Shell and PowerShell Policy
- Use `powershell -NoProfile -NonInteractive` for Windows script execution.
- Do not use `-ExecutionPolicy Bypass`.
- Prefer repo scripts over large inline command blocks when a script exists.

## Deterministic Execution Order
Run validations in this order and stop at the first failing gate:
1. Gate 0: Environment preflight
2. Gate 1: Integration example smoke
3. Gate 2: Image verifier smoke
4. Gate 3: Image contract certification
5. Gate 4: Phase-3/PPL throughput work

## Gate Definitions

### Gate 0: Environment Preflight
- Verify Docker server mode is `windows` before any Windows image flow.
- Verify target image availability (inspect; pull/acquire if remote).
- Verify required local paths/scripts exist before run dispatch.
- Preflight failures are execution/preparation failures, not CLI runtime failures.

### Gate 1: Integration Example Smoke
- Use `examples/integration-into-cicd/runlabview.ps1`.
- Always pass explicit `-LabVIEWYear` or explicit `-LabVIEWPath`.
- Treat default-year assumptions as unsafe when image year differs.

### Gate 2: Image Verifier Smoke
- Use `examples/build-your-own-image/verify-lv-cli-masscompile-from-image.ps1`.
- Use explicit `-LvYear` and `-LvCliPort`.
- Capture and preserve diagnostics (summary, netstat, process list, INI snapshots, temporary logs).

### Gate 3: Image Contract Certification
- Use `examples/build-your-own-image/certify-image-contract.ps1`.
- Publish and preserve `builds/status/image-contract-cert-summary-*.json`.
- Certification classification is authoritative for pass/fail decisions.

### Gate 4: Phase-3/PPL Throughput
- Start only after Gate 3 (or explicit exception approved in issue/PR).
- Throughput track must not silently alter 2020 promotion policy.

## Split-Track Strategy

### Track A: 2026 Throughput
- Objective: keep artifact throughput green.
- Expected lane: hosted 2022.
- Acceptable for delivery while 2020 stabilization is ongoing.

### Track B: 2020 Stabilization
- Objective: remove non-determinism and satisfy promotion gate.
- Prefer self-hosted real Server 2019 lane for promotion eligibility.
- Keep canonical `labview-custom-windows:2020q1-windows` frozen until gate passes.

## Promotion Guardrail (2020 Canonical Tag)
Do not retag canonical 2020 image unless two consecutive fresh runs satisfy all:
- `final_exit_code = 0`
- `contains_minus_350000 = false`
- `port_listening_before_cli = true`
- certification summary indicates promotion eligibility.

## Failure Taxonomy and First Response
- `environment_incompatible`
  - Fix runner/OS lane first; do not tune image yet.
- `verifier_execution_error`
  - Fix preflight/acquisition/script execution path first.
- `port_not_listening`
  - Focus on LabVIEW readiness/launch timing and listener diagnostics.
- `cli_connect_fail`
  - Focus on CLI-to-LabVIEW connectivity and retry semantics.

## Headless Runtime Rules
- Headless and interactive IDE sessions are mutually exclusive.
- If a UI/IDE session was launched, close it before headless CLI automation.
- Prefer passing `-Headless` explicitly for clarity/reliability.
- For triage, always capture console output plus LabVIEW/LabVIEWCLI logs.

## Evidence Contract
For every non-trivial run, persist:
- run command/context
- output summary JSON
- key diagnostics (`netstat`, process list, INI snapshots, temp logs)
- link to workflow run URL when run in CI
- classification and next action in one short conclusion

## GitHub Workflow and Issue Discipline
- Reference issue IDs in commit messages/PR descriptions (`Refs #<issue>`).
- Document classification outcomes in issue comments with artifact paths.
- If an issue is already closed, open a new issue for new scope rather than overloading the closed one.

## Source-of-Truth Files
- `docs/windows-custom-images.md`
- `docs/faqs.md`
- `.github/workflows/labview-image-contract-certification.yml`
- `examples/build-your-own-image/certify-image-contract.ps1`
- `examples/build-your-own-image/verify-lv-cli-masscompile-from-image.ps1`
- `examples/build-your-own-image/build-windows-lv2020x64-resumable.ps1`
