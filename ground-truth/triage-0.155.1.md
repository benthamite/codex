# Protocol triage: Codex 0.155.1

## Current inventory

The complete experimental inventory is now reviewed: **258 methods, 97 named
in the client, 159 deliberately excluded, 2 todo, zero unreviewed**. The
additional 63 methods comprised 7 already handled, 50 scope exclusions and
6 follow-ups. These counts are method coverage, not feature parity.

[The remaining feature work](parity-worklist.md) includes gaps a method-name
check cannot detect. The sections below preserve the evidence and corrections
that led to this inventory.

## Initial non-experimental triage

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
| `thread/turns/list`, `thread/items/list` | 2 | Defer implementation; todo, first priority | Resolve history hydration compatibility. The experimental schema supports `initialTurnsPage`, contrary to the original stable-only inspection. A real 103-turn fixture confirms resume returns only 100 turns initially; the client ignores the continuation cursor. Fork returns no initial page. Local JSONL replay masks these gaps. Capture resume without an available local transcript and determine whether full turn pages suffice or item pages are also needed. |
| `autoApprovalReview/strictReviewRequired` | 1 | Defer implementation; todo | Capture a strict-review wait and its CLI presentation. Do not assume equivalence with existing guardian warnings. |
| `modelProvider/authRecoveryStarted`, `modelProvider/authRecoveryCompleted` | 2 | Defer implementation; todo | Capture authentication-recovery messages and event ordering for status rendering. |
| `thread/realtime/item/started`, `thread/realtime/item/transcript/delta`, `thread/realtime/item/completed` | 3 | Defer implementation; todo | Capture canonical and legacy events together before adding item-aware rendering and deduplication. |
| `thread/revert`, `thread/reverted` | 2 | Defer implementation; todo | Reconsider the old deprecated rollback exclusion. Establish the CLI interaction and hydrate retained history. This edits conversation history, not files. |
| `thread/queue/changed` | 1 | Defer implementation; todo investigation | Establish the trigger and how server queue state is retrieved. The notification contains only a thread ID; experimental queue list/mutation methods exist, but its relationship to the local Tab queue is unproven. |
| `mcpServer/event/stream/notification` | 1 | Defer implementation; todo investigation | Capture the experimental stream/start and stream/stop subscription mechanism and a relevant emitting scenario before deciding on presentation. |
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
  original `initialTurnsPage` mismatch claim was incorrect: that field is
  experimental and the client opts into it. Pagination and fork rendering
  still require behavioral checks beyond method-name coverage.
- Re-running `protocol_coverage.py` after triage must report no new, removed or
  regressed methods, zero unreviewed methods, and the 13 explicit todo entries.

## Experimental-schema correction

The follow-up investigation found that the detector omitted `--experimental`,
even though the Emacs client advertises `experimentalApi: true`. The corrected
detector inventories 258 methods: 63 more than the original review. These are
newly visible to the detector, not necessarily new in Codex 0.155.1. They remain
outside the reviewed baseline, so the detector intentionally reports drift
until a separate triage records decisions. The earlier zero-unreviewed result
applied only to the 195-method non-experimental subset.

Read-only schema checks and a disposable local app-server fixture used an
isolated CODEX_HOME, a loopback-only model provider, and no model turns or
credentials. The real server accepted initialTurnsPage, returned 100 of 103
turns plus a continuation cursor, and returned all 103 fork turns in
thread.turns without an initialTurnsPage field. These observations supersede
the original schema-mismatch hypothesis.

## History follow-up completed

Both resume and fork now request metadata with `excludeTurns: true`, prefer
displayable local transcript history, and otherwise load ascending
`thread/turns/list` pages with `itemsView: full` until `nextCursor` is null.
Input is held until hydration finishes; external submissions during loading
are rejected explicitly. A failed page displays an incomplete-history warning.
`thread/turns/list` is now handled; `thread/items/list` is excluded because full
turn pages supply this interface. The original 25 additions now have 11 todo,
13 exclusions and one handled method.

Live acceptance used the same independent synthetic 103-turn session on
Codex 0.155.1. The official TUI rendered in Eat, native Emacs resume, and native
Emacs fork each contained exactly 103 user messages and 103 assistant replies
in chronological order. Resume retained fixture identity
`28e89cc7-d0b0-4ba6-b876-10121ac1ec7e`; fork created a distinct thread with the
same history. A transparent transport proxy replaced server transcript paths
with unavailable paths, leaving requests and history payloads intact; this
forced the native clients to exercise protocol hydration rather than JSONL
replay. Actual requests fetched two pages per native path. No model turns,
credentials, shared accounts, or pre-existing threads were used.

This establishes complete idle-thread history hydration, not pixel-identical
rendering. A subsequent two-process test used a copied 103-turn fixture and a
slow loopback provider: the second app-server rejected resume with -32600,
“already has an active writer”. It never entered hydration. The proposed live
interleaving route therefore did not reproduce in the current per-buffer
stdio architecture; shared-server transports remain a separate untested case.
All 418 ERT tests, shell/Python checks, strict byte compilation, and manual
Texinfo export/validation passed. The Makefile needed the installed `llama`
dependency supplied through `LOAD_PATH_EXTRA`; the Python TUI harness lacked
`pyte`, so the reference capture used the existing Eat terminal backend.

## Completed experimental triage

The follow-up inspected the installed experimental schema and official tagged
`rust-v0.155.1` source. Every new method now has a reason in the baseline.
Important scope corrections:

- Keep the local Tab queue. The TUI owns `queued_user_messages` locally and
  ignores `ThreadQueueChanged`. The durable queue API serves separate
  `codex session queue` commands; adopting it is not necessary for this UI.
- Preserve source history when editing an earlier prompt. The official TUI
  sends `ForkSessionForPromptEdit`; it does not use in-place `thread/revert`,
  and ignores `ThreadReverted`. Track prompt-edit branching separately.
- Ignore canonical realtime item notifications just as the TUI does. They
  duplicate legacy transcript events. Final legacy transcript reconciliation
  and persisted realtime history remain separate correctness questions.
- Keep existing plugin listing: it already triggers background reconciliation
  through the same upstream implementation as explicit `plugin/reconcile`.
- Exclude hosted-app MCP event subscriptions from this terminal interface;
  the TUI ignores their notifications.
- Correct the old process-family note: these methods expose standalone
  unsandboxed process control, not a proven deprecated predecessor.

Primary source anchors are the tagged TUI `chatwidget/protocol.rs`,
`chatwidget/input_queue.rs`, `app_backtrack.rs`,
`app/background_requests.rs`, app-server `request_processors/plugins.rs`,
and core-plugins `manager.rs`. Decisions are source/schema conclusions, not
new live parity claims.

## Live follow-up acceptance

The installed 0.155.1 TUI was exercised inside Eat with isolated homes and
owned threads. Native acceptance used the same installed app-server and a
loopback model provider, without account credentials or paid requests.

- Recovery/strict-review notices match captured TUI text and prefixes under
  explicit transport injection. Their real backend triggers were not tested.
- Plan/Default selection uses discovered presets. Native Plan selected medium
  effort, Default restored high, and an inline Plan prompt completed with
  collaboration settings present in the actual turn request.
- External-clock requests reached native Emacs from the real server; whole
  Unix-second responses produced the corresponding reminder at the provider.
- A mixed ordinary/realtime history fixture resumed successfully, but
  `thread/timeline/list` returned -32601, “not supported yet”. That endpoint is
  deferred until server support exists.

See the worklist for remaining behavior gaps; named-method counts do not
measure completed feature parity.

MCP follow-up captured actual form/approval UI from a disposable MCP server.
Native forms returned the same string, false boolean, and enum values as the
CLI. Session approval suppressed the next tool approval, and the client
permanent-response encoding persisted across fresh server processes. Canceling
a live native form sent `action:cancel` and allowed the turn to complete.
Unsupported native-identity requests now explicitly cancel; this is not
biometric support.

Realtime acceptance used the actual TUI caption renderer while connecting,
with an isolated bridge intercepting realtime requests before any SDP answer
or audio device access. The same injected notifications passed through the
live native JSON dispatcher. Caption text, speaker prefixes and finalization
order matched for corrected finals, final-only messages, interleaved speakers
and successive captions sharing a prefix. This verifies rendering, not a
working voice-service connection.

Memory controls were compared with actual CLI use/generate/reset and feature
enablement flows. The native menu persisted both booleans and changed the
current thread memory mode; confirmed reset removed owned v1/v2 memory files
and preserved all eight fixture threads. A real sparse config response
exposed null-versus-false ambiguity, now covered by a captured-shape regression
and live readback returning false use / true default generation.
