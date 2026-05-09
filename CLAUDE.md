# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo is an **asset pipeline and release harness** for a chibi-mascot sprite pack ("xinxin"). The deliverable is a sprite atlas (`final/spritesheet.png` + per-state PNGs) generated via an `$imagegen` skill from prompts, then audited and gated before release. There is no application code — the "product" is the JSON contracts, prompts, generated frames, and the PowerShell + GitHub Actions automation that governs their production and release.

`xinxin-run/` is the only live run directory. The README note that `kea-run` is history-only still applies — it has already been removed; do not recreate or reference it.

## Conventions (important)

- **All automation is PowerShell (`.ps1`).** Commands in docs assume Windows paths (`D:\pet`, backslashes). On macOS/Linux use `pwsh` and translate paths to `./xinxin-run` etc. Do not rewrite scripts to bash — the CI workflows invoke them via `powershell -ExecutionPolicy Bypass -File ...`.
- **Script docs live in `scripts/README.md`**, which is the authoritative index of every `.ps1` entry point and its flags. Read it before adding a new script or changing a flag — downstream scripts and workflows consume the documented fields (`health_status`, `remediation_plan_steps`, `release_cycle_board_*`, etc.) by name.
- **JSON outputs are the contract between stages.** Adding or renaming a field in one stage's output (e.g. `run-status.json`, `release-gate.json`, `recovery-cycle-report.json`) can silently break a later stage or a CI workflow that greps for it. Search the other scripts and `.github/workflows/*.yml` before changing a field name.
- **Run artifacts are timestamped** (`run-audit-YYYYMMDD-HHmmss.json`, `run-log-*.md`). Most scripts default to "read the newest" when a specific `-AuditFile` / `-ReportPath` is not passed. Preserve that convention.

## Pipeline architecture

The pipeline is layered — each stage reads the outputs of earlier stages. When making changes, identify which layer you are in:

**Layer 1 — Run definition (inputs):**
- `xinxin-run/pet_request.json` — IP contract, atlas geometry (`columns`, `rows`, `cell_width`/`height`), per-state `frames` counts, palette/identity guardrails, `canonical_identity_reference` with SHA-256.
- `xinxin-run/imagegen-jobs.json` — DAG of image-gen jobs (`base`, then per-state `row-strip` jobs with `depends_on`), each with `status`, `output_path`, `output_sha256`.
- `xinxin-run/prompts/` — `base-pet.md`, `xinxin-ip-contract.md`, and per-state prompts in `rows/` (plus versioned `rows/v2/`).
- `xinxin-run/references/` — `canonical-base.png` (identity anchor), `reference-01.png`, `layout-guides/*.png` (spacing-only inputs, guide lines must not be copied into outputs).

**Layer 2 — Generated artifacts:**
- `decoded/` — raw imagegen outputs (base + one per state).
- `frames/<state>/00.png … NN.png` — sliced frames matching `pet_request.json` frame counts, plus `frames/frames-manifest.json`.
- `final/` — `spritesheet.png`/`.webp`, per-state composed PNGs, `validation.json`.

**Layer 3 — Status and audit (reads Layer 1+2, writes to `qa/`):**
- `collect-pet-run-status.ps1` → `qa/run-status.json` (existence checks, frame-count vs. `expected/frame-count`, job `pending/failed` counts, `gate.ready_for_generation`, readiness score).
- `audit-xinxin-v2.1.ps1` → `qa/run-audit-<ts>.json` (PASS/FAIL matrix).
- `build-xinxin-delivery-manifest.ps1` → `qa/delivery-manifest.json` (with SHA-256).
- `generate-pipeline-manifest.ps1` → `pipeline-manifest.json` at repo root (cross-run summary; `-IncludeAllRuns` to scan beyond `xinxin-run`).

**Layer 4 — Review, log, gate (reads Layer 3):**
- `set-v2.1-manual-review.ps1` writes reviewer decisions into the latest `run-audit-*.json` (don't hand-edit markdown).
- `generate-v2.1-run-log.ps1` → `qa/run-log-<ts>.md` from the audit.
- `check-v2.1-release-gate.ps1` requires `audit.overall=PASS` + `manual_review.status=PASS` + `run-status.gate.ready_for_generation=true`; use `-RequirePass` for strict block.

**Layer 5 — Orchestration:**
- `run-xinxin-v2.1.ps1 -Mode check|pack|audit|log|all|full|gate` — single-invocation of any subset.
- `run-xinxin-v2.1-release-line.ps1 -Line baseline|gate|all` — the "release line" entry point used by CI.
- `execute-xinxin-recovery-cycle.ps1` — runs `baseline` → `gate` → `all` in sequence, each in its own bundle, then emits `recovery-cycle-report.json` and digest.
- `run-xinxin-release-command-center.ps1` — wraps the recovery cycle + board generation into one command; the canonical pre-release entry point. Emits `command-center-summary.{json,md}` and, under GitHub Actions, writes outputs to `$GITHUB_OUTPUT`.

**Layer 6 — Next-action / recovery (consumed by humans and CI):**
- `resolve-xinxin-next-action.ps1` → structured JSON + optional markdown with `recommended_command` / `recommended_step` / `recommended_reason`.
- `collect-xinxin-next-artifacts.ps1` → `next-action-collect.json` with `health_status` / `health_score` / `needs_attention` / `health_gate.*`. The `-FailOnAttention` / `-FailOnCritical` / `-MinHealthScore` flags are the **single source of truth** for the CI health gate (defaults: false / true / 70).
- `infer-xinxin-remediation-plan.ps1` → `remediation-plan.{json,md}` from a collect snapshot.
- `summarize-xinxin-recovery.ps1` → `recovery-digest.{json,md}` (falls back to `collect`/`remediation`/`next-action` artifacts when `release-line-report.json` is missing).
- `build-xinxin-recovery-board.ps1` → `release-cycle-board.{json,md}` (handoff board).

## CI (`.github/workflows/`)

Six workflows, all calling the same PowerShell scripts. Pick the matching entry point when modifying CI behavior:

- `xinxin-v2.1-pr-dry-run.yml` — PR trigger, non-blocking.
- `xinxin-v2.1-dry-run.yml` — manual dry-run.
- `xinxin-v2.1-release-gate.yml` — blocking pre-release gate.
- `xinxin-v2.1-on-release-gate.yml` — fires on `release` publish, blocking.
- `xinxin-v2.1-release-check.yml` — combined one-shot path; accepts `require_release_gate`.
- `xinxin-v2.1-release-line.yml` — `workflow_dispatch` with `line=baseline|gate|all`; the recommended CI path.

All six produce `run-status.json` in the artifact bundle. Shared knobs:
- `run_id_prefix` (batch tag for artifact names), `retention_days`, `run_command_center` (toggle command-center diagnostics on failure).
- Repo variables `XINXIN_*_RUN_COMMAND_CENTER` (per-workflow default for `run_command_center`) and `XINXIN_HEALTH_GATE_FAIL_ON_ATTENTION` / `_FAIL_ON_CRITICAL` / `_MIN_HEALTH_SCORE` (health gate thresholds; defaults `false` / `true` / `70`).

## Common commands

From repo root (translate paths as needed on non-Windows):

```powershell
# Quick health check
powershell -ExecutionPolicy Bypass -File .\scripts\collect-pet-run-status.ps1 -RunDir .\xinxin-run

# Pipeline check + init missing dirs + hard gate
powershell -ExecutionPolicy Bypass -File .\scripts\run-pet-workflow.ps1 -RunDir .\xinxin-run -CreateStructure -RequireHealthy

# Full local run: check -> pack -> audit -> run-log, with release-gate
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1.ps1 -Mode all -RunDir .\xinxin-run -RequireReleaseGate

# CI-equivalent release line
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-v2.1-release-line.ps1 -Line all

# One-shot pre-release: recovery cycle + board + command-center summary
powershell -ExecutionPolicy Bypass -File .\scripts\run-xinxin-release-command-center.ps1 -RunIdPrefix release-<date> -RunDir .\xinxin-run -HumanReadable

# Record a manual state review into the latest audit (don't hand-edit markdown)
powershell -ExecutionPolicy Bypass -File .\scripts\set-v2.1-manual-review.ps1 -RunDir .\xinxin-run -StateReview idle:PASS -StateReview waiting:PASS -Reviewer <name>
```

No test suite, linter, or build system — correctness is asserted by `audit-xinxin-v2.1.ps1` + `check-v2.1-release-gate.ps1`. Treat a green release gate as the equivalent of a passing test run.
