# Verification and local operations

Run commands from the repository root. The wrappers resolve their own root, so IDE working-directory differences do not change their meaning. They require no IDE plugin or RTK installation; if your personal shell policy requires RTK, invoke them with `rtk proxy`.

## Prerequisites

Use Git, Bash, Python 3.9+, Rust/Cargo via rustup, and Node/npm. The Rust toolchain is specified in [rust-toolchain.toml](../../rust-toolchain.toml); the frontend container uses Node 24 in [its Dockerfile](../../frontend/Dockerfile). Prefer Node 24 locally too. Install frontend dependencies with `npm --prefix frontend ci`. Cargo uses [Cargo.lock](../../Cargo.lock); npm uses [package-lock.json](../../frontend/package-lock.json).

Docker with Compose v2 is needed for runtime inspection and acceptance suites. GitHub operations use `gh` with the user's existing authorized login. Some older acceptance scripts additionally need `jq` and `curl`; inspect their prerequisites. Keep credentials in the existing setup paths and secret volumes, never in these documents.

## Shared commands

| Command | What it does |
| --- | --- |
| `python3 scripts/doctor.py` | Read local Git state and installed tool versions |
| `python3 scripts/doctor.py --runtime` | Also inspect Compose health, image drift, and applied migration checksums; no service starts or database writes |
| `python3 scripts/doctor.py --runtime --json` | Same observations as structured output, with warnings/failures distinguished |
| `bash scripts/verify.sh context` | Check shared documentation links and run doctor regression tests; no Docker or model calls |
| `bash scripts/verify.sh backend` | Locked Cargo tests and formatting |
| `bash scripts/verify.sh frontend` | Frontend typecheck, tests, and production build |
| `bash scripts/verify.sh` | Context, backend, frontend, and Git whitespace checks |

Verification writes normal build artifacts; it does not migrate the running database, start workers, or send model requests. Ignored integration tests are not covered by the default Cargo run; select the applicable acceptance suite explicitly.

## Acceptance selection

| Changed behavior | Additional acceptance script(s) |
| --- | --- |
| Seed (campaign)/creator/similarity/research retry | `bash scripts/research_campaign_test.sh` |
| Provider capacity/spending/recovery | `bash scripts/openrouter_capacity_test.sh` |
| Manual research intake | `bash scripts/incubator_manual_requests_test.sh` |
| Evaluation/refinement/experiment | Corresponding `incubator_evaluation_test.sh`, `incubator_refinement_test.sh`, `incubator_experiment_test.sh` in [scripts](../../scripts) |
| Migration machinery | `bash scripts/wu02_migration_test.sh` |
| Other numbered WU | Its matching acceptance script and SQL fixture |

Inspect a suite before running it: identify its Compose project, published ports, cleanup targets, required tools, and evidence files. Older suites may stop other test projects. Never substitute the live project's name or database for a disposable test target. Do not run suites against shared ports/projects concurrently. Record which checks ran, their commit/tree, and whether they used fixtures or live services.

## Runtime changes

A build is not a deployment. Rust embeds migrations at build time. Compare source migration hashes, stored hashes, and the running image before diagnosing a mismatch. The doctor detects live database/source differences and container/tag differences; it does not prove that a local image tag was built from the current commit.

Starting/restarting a configured worker can resume paid creator calls, research, or data acquisition. Inspect seed (campaign)/policy state and the user's authorization before changing runtime. Use the existing Compose definitions and explicitly scoped services. Apply migrations with the newly built backend's `backend migrate` command only when deployment is in scope. Recheck readiness and actual image IDs afterward. Preserve volumes and applied migration history.

## Maintaining evidence

Update source-hash evidence after changing a checksum-bearing input. Never claim success from an older commit without verifying tree equivalence and disclosing the tested tree. Keep raw temporary logs in ignored `.scratch/`; commit source and relevant JSON evidence. Browser checks are additional evidence for changed UI behavior, not a replacement for tests.
