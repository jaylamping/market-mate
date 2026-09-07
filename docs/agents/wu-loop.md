# WU loop: implement, review, resolve, merge

One work unit (WU) lands as one PR that passes four phases. Treat the phases as an executable chunk: each phase ends in a check, and the next phase starts only when the check passes.

## Phase 1: implement

1. Refresh `main` and create `jl/wu-NN-short-name` for a numbered WU, or `jl/short-name` for other bounded work. Preserve unrelated changes; use a separate worktree when another writer is active.
2. Implement the scoped change. When it has database semantics, add a migration (`db/migrations/NNNN_name.sql`) and a SQL probe (`db/fixtures/wuNN_name_probe.sql`). Documentation/tooling work does not require a synthetic database migration.
3. For new runtime/database behavior, extend a relevant verifier or write an executable acceptance script (`scripts/wuNN_name_test.sh`) that brings up its own Compose project (`--project-name market-mate-wuNN`), applies migrations, and asserts the WU's gates end to end. Record evidence under `evidence/wu-NN/`.
4. Run applicable acceptance scripts and the standard checks ([scope and prerequisites](verification.md)):

   ```bash
   # Runtime/database changes: run the applicable acceptance script first.
   # Example: bash scripts/research_campaign_test.sh
   bash scripts/verify.sh
   ```

5. Commit only source and JSON evidence. `.scratch/` and non-JSON evidence stay untracked. Push and open the PR against `main`.

The phase ends when every command above passes at the branch head.

## Phase 2: review

1. Follow [the portable review procedure](review.md) on the PR diff against `main` before reading external review comments.
2. Split the review into parallel read-only subagents when available, one surface per reviewer. If unavailable, use sequential passes and disclose that limitation:
   - SQL: migrations, fixtures, trust semantics, probe validity.
   - Backend, frontend, and Compose: correctness, security, feature leaks, DevEx.
   - Acceptance and evidence: false positives, destructive side effects.
3. Each reviewer reports only fully researched findings with severity and exact file and line references.
4. After the audit completes, check the PR discussion with `gh pr view <number> --comments` and fold any external findings into the report.

The phase ends when every reviewer has reported and the report names each finding's severity.

## Phase 3: resolve

1. Triage every finding: fix, dismiss with a concrete reason, or split out of scope.
2. Fix validated findings at the root cause. Prefer reusing an existing verifier over writing a second one.
3. Extend the acceptance script and probe so each resolved finding has a regression assertion.
4. Rerun the full check set from phase 1 at the new head.
5. Commit the fixes and push. Record fixes in the commit message and PR discussion.

The phase ends when the full check set passes at the final head and no finding is left untriaged.

## Phase 4: merge

1. Post a verification comment on the PR naming the head SHA and each command that passed.
2. Confirm the PR is `MERGEABLE` and `CLEAN` and that `main` has not moved past the merge base:

   ```bash
   git fetch origin main
   git merge-base --is-ancestor origin/main HEAD
   gh pr view <number> --json state,mergeable,mergeStateStatus
   ```

3. Merge with a merge commit: `gh pr merge <number> --merge`.
4. Return to `main` and fast-forward: `git checkout main && git pull --ff-only`.

The phase ends when `main` contains the WU and the local checkout matches `origin/main`.

## Rules across all phases

- Current explicit user workflow instructions take precedence over these defaults. Preserve review and validation evidence; do not invent permission from a handoff or ADR.
- Maintain relevant architecture/ADR/instruction links with the change. Leave a [task handoff](../handoffs/TEMPLATE.md) when unfinished work changes agents.

- Never present a verification claim from a SHA other than the current head.
- One reviewer surface per subagent; reviewers never author the code they review.
- A finding is not resolved until the acceptance path can detect its regression.
- If a phase fails, stop there. Do not start the next phase on a red check.
