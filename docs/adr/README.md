# Architecture decision records

ADRs explain consequential choices that are not obvious from the code. Read only the decisions relevant to a task. Records 0001–0005 document existing implementation retrospectively on 2026-09-07; 0006 records the newly approved agent-context arrangement. None creates trading, spending, or deployment authority.

| Record | Decision |
| --- | --- |
| [0001](0001-research-authority-boundary.md) | Separate research output from trading authority |
| [0002](0002-immutable-migration-bytes.md) | Preserve applied migration bytes |
| [0003](0003-uncertain-provider-outcomes.md) | Preserve uncertain provider acceptance |
| [0004](0004-request-failures-and-linked-retries.md) | Link failures and new retries to originating requests |
| [0005](0005-model-and-spending-authorization.md) | Separate model availability, selection, and spending authorization |
| [0006](0006-portable-agent-context.md) | Keep shared agent context in the repository |
| [0007](0007-campaign-backlog-pickup.md) | Keep existing campaign backlog moving |
| [0008](0008-campaign-experiment-throughput.md) | Pace backlog claims below capacity; retry unusable Experiment replies |
| [0009](0009-acquisition-worker-timeout.md) | Acquisition worker timeout; retry exhausted `commit_rejected` |
| [0010](0010-research-retry-campaign-paid.md) | Retry unusable Research Scout replies; campaign paid creator for research |

Use [TEMPLATE.md](TEMPLATE.md). Record status, evidence, consequences, rejected alternatives, and conditions for reconsideration. An accepted design can still be unimplemented: record implementation status separately. Link a superseded record to its replacement. Update this index and affected instructions in the same PR as a decision change.
