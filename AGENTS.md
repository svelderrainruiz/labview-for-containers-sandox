# Agent Working Contract

## Scope
These instructions apply to this repository (`labview-for-containers`) and should be used by coding agents working in this repo.

## Safety Rules
- Do not run destructive git commands (`reset --hard`, `checkout --`) unless explicitly requested.
- If the current worktree is dirty, use an isolated git worktree for integration work.
- Keep evidence logs under `TestResults/agent-logs` and do not delete prior diagnostic bundles unless requested.

## Shell and PowerShell Policy
- Use `powershell -NoProfile -NonInteractive` for Windows script execution.
- Do not use `-ExecutionPolicy Bypass`.
- Prefer repository scripts over ad-hoc inline command blocks when a script already exists.

## Windows Container Preflight
Before running Windows image or certification flows:
- Confirm Docker server mode is `windows`.
- Confirm the requested image tag exists locally, or acquire it explicitly.
- Fail fast on preflight failures and classify them distinctly from runtime LabVIEWCLI failures.

## Certification and Classification
- Use `examples/build-your-own-image/certify-image-contract.ps1` for image-contract certification.
- Always persist `builds/status/image-contract-cert-summary-*.json` and associated run logs.
- Treat missing-image/preflight failures as `verifier_execution_error`.

## 2020 Promotion Guardrail
- Keep canonical `labview-custom-windows:2020q1-windows` frozen until certification gates pass.
- Promotion requires two consecutive fresh passes with:
  - `final_exit_code = 0`
  - `contains_minus_350000 = false`
  - `port_listening_before_cli = true`

## Branching and Traceability
- Prefer feature branches named by issue scope.
- Reference issues in commit/PR descriptions (for example `Refs #<issue>`).
- Keep changes minimal and scoped to a single concern per branch whenever possible.
