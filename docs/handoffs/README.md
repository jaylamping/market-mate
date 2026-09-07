# Task handoffs

Use [TEMPLATE.md](TEMPLATE.md) when unfinished work moves to another agent, IDE, or machine. Save one file per task as `YYYY-MM-DD-issue-or-task.md`; independent tasks must not overwrite one shared status file.

Keep a handoff short and link to source, issues, PRs, and evidence. Record its timestamp and commit. Label operational observations as snapshots, since containers, approvals, branches, and databases can change independently of Git. Never copy credentials or full conversation transcripts.

The incoming agent verifies the snapshot before acting. The issue/PR holds current work status; a handoff is a navigation aid, not a lock or authorization grant. After completion, mark the handoff completed and point to the final PR, or keep completion solely in the PR when no handoff was needed.
