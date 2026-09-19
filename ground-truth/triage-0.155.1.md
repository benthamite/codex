# Protocol triage: Codex 0.155.1

Reviewed on 2026-09-19 against the previous 0.145.0 baseline. All 25 new
methods have decisions: 13 `todo`, 12 `wont-implement`. No methods disappeared.
The baseline also now recognizes the existing `skills/changed` handler, bringing
the total to 82 handled, 100 excluded and 13 todo across 195 methods.

This is schema and source triage, not a completed CLI parity comparison.
`todo` includes follow-up investigation: it does not commit us to implementing
every candidate. `wont-implement` records current interface scope, not proof
that a feature is absent from the terminal CLI. Per-method evidence and reasons
are in [protocol-baseline.json](protocol-baseline.json).

## Decisions and follow-up order

| Methods | Count | Decision | Follow-up |
| --- | ---: | --- | --- |
| `thread/turns/list`, `thread/items/list` | 2 | Defer implementation; todo, first priority | Resolve history hydration compatibility. The client requests and reads `initialTurnsPage`, absent from the installed schema. Local JSONL replay may hide the mismatch. Capture resume without an available local transcript and determine whether full turn pages suffice or item pages are also needed. |
| `autoApprovalReview/strictReviewRequired` | 1 | Defer implementation; todo | Capture a strict-review wait and its CLI presentation. Do not assume equivalence with existing guardian warnings. |
| `modelProvider/authRecoveryStarted`, `modelProvider/authRecoveryCompleted` | 2 | Defer implementation; todo | Capture authentication-recovery messages and event ordering for status rendering. |
| `thread/realtime/item/started`, `thread/realtime/item/transcript/delta`, `thread/realtime/item/completed` | 3 | Defer implementation; todo | Capture canonical and legacy events together before adding item-aware rendering and deduplication. |
| `thread/revert`, `thread/reverted` | 2 | Defer implementation; todo | Reconsider the old deprecated rollback exclusion. Establish the CLI interaction and hydrate retained history. This edits conversation history, not files. |
| `thread/queue/changed` | 1 | Defer implementation; todo investigation | Establish the trigger and how server queue state is retrieved. The notification contains only a thread ID; its relationship to the local Tab queue is unproven. |
| `mcpServer/event/stream/notification` | 1 | Defer implementation; todo investigation | Find the subscription mechanism and a relevant emitting scenario before deciding on presentation. |
| `plugin/reconcile` | 1 | Defer implementation; todo investigation | Determine whether plugin refresh should request reconciliation and how the CLI reports failures. A response is not a runtime-readiness guarantee. |
| `thread/attachment/add`, `thread/attachment/list`, `thread/attachment/remove`, `thread/attachment/updated` | 4 | Skip; wont-implement | Stored resource associations, such as linked pull requests. Revisit if we add that interface; these are not prompt file/image attachments. |
| `project/changed`, `thread/project/updated` | 2 | Skip; wont-implement | No server-project association display or cache. Local working directories are a separate concept. |
| `threadSection/create`, `threadSection/delete`, `threadSection/list`, `threadSection/update`, `thread/section/move` | 5 | Skip; wont-implement | No section-aware thread picker or section cache. |
| `externalAgentConfig/import/recordHistory` | 1 | Skip; wont-implement | Import-result bookkeeping belongs to the already excluded external-agent migration workflow. |

## Evidence and limits

- Generated the schema with the installed `codex-cli 0.155.1` and inspected
  request, response and notification definitions alongside `codex-app-server.el`.
- Consulted the [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
  and the [version-pinned upstream README](https://github.com/openai/codex/blob/rust-v0.155.1/codex-rs/app-server/README.md),
  especially the stored-attachment semantics.
- Did not send model turns, alter existing threads, invoke reconciliation or
  change account authentication. None of the 25 methods is newly marked handled.
- The detector checks method names, not parameter/response compatibility. The
  `initialTurnsPage` mismatch illustrates a gap outside that check. Its
  user-visible effect remains to be measured before a repair is chosen.
- Re-running `protocol_coverage.py` after triage must report no new, removed or
  regressed methods, zero unreviewed methods, and the 13 explicit todo entries.
