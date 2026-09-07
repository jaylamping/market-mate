# Automatic research refinement

A current evaluation that returns `refine` queues one bounded revision attempt on the same research ticket. The worker uses the approved free research runner, with a zero-price provider limit and the shared model capability adapter. A paid model selected for the original manual assignment does not authorize automated paid refinement.

Each attempt is recorded before dispatch. At most two attempts may exist per run key, across every automatic and manual report revision. Duplicate dispatches are rejected. An interrupted attempt is recorded as indeterminate rather than replayed. Preparation failures, invalid responses and explicit model blockers stop for owner input.

A successful response includes a complete validated report and an explanation of changes. The database appends an agent-origin report revision; normal evaluation queues that revision automatically. Original reports, evaluator feedback and previous revisions remain readable. A manual edit made during dispatch takes precedence: the late automatic result is retained as superseded and does not replace the owner's revision.

Unchanged reports and repeated normalized evaluator feedback stop the loop. The refinement prompt also asks the model to stop for semantically repeated issues, missing external evidence needed to revise responsibly, or unresolved owner decisions. Semantic judgments remain model judgments; the durable two-attempt ceiling is enforced independently in PostgreSQL.

The UI shows Refining with the round number, Re-evaluating, or Needs your input with the blocker. Owners can use Chat to propose and apply a revision. Applying a manual revision does not replenish the automatic allowance. Archived tickets do not start new refinement attempts; archiving does not cancel an already dispatched request.

Validation: `bash scripts/incubator_refinement_test.sh` exercises the migration and database boundaries in an isolated database. Rust tests cover the model response contract, and frontend tests cover progress and blocked-input presentation.
