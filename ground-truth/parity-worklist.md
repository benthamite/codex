# Remaining terminal-UI parity work

This tracks behavior rather than method-name coverage. The protocol baseline
records method decisions; an entry marked handled there can still have a
behavioral gap here. Evidence is for installed Codex 0.155.1.

| Work | Decision | Evidence needed |
| --- | --- | --- |
| Render authentication recovery and strict-review notices | Done | Controlled notifications rendered in actual TUI/Eat and native Emacs with matching text and prefixes; thread filtering tested. Real credential recovery and review triggering were not exercised. |
| Select server-discovered Plan/Default modes | Done | Actual CLI preset/settings capture; native `/plan` selected medium, `/default` restored high, and `/plan text` completed a loopback turn carrying the mode. FIFO and selection-failure regressions tested. |
| Answer external-clock requests | Done | Native Emacs answered real external-clock callbacks with whole Unix seconds; the resulting time reminder reached the loopback model and the turn completed. |
| Match `/memories` controls | Done | Live native menu toggled both knobs on/off; disk config and thread generation followed. Reset cleared owned v1/v2 sentinels and preserved all eight threads. Disabled feature enabled only for future threads. Sparse config readback distinguishes false from null/default true. |
| Preserve final realtime transcript text | Done for caption rendering | Actual TUI and native captures match corrected-final, done-only, interleaved-role completion order and distinct same-prefix captions. Native input survives. Notifications were injected; no voice backend or audio acceptance is claimed. |
| Hydrate persisted realtime history | Defer: server unsupported | Actual 0.155.1 server resumed an owned mixed-history fixture and served ordinary turn pages, but `thread/timeline/list` returned -32601, “not supported yet”. Revisit after server support exists. |
| Branch before an earlier prompt for editing | Investigate | Capture the current source-preserving CLI backtracking flow; do not substitute destructive in-place revert. |
| Support native user verification | Defer pending safe capture | The CLI requests native identity proof during some MCP elicitations. Exercise cancellation/error paths with isolated requests; a real proof may require the user's biometric interaction. |
| Complete MCP elicitation choices and forms | Done for supported form types | Actual CLI and native forms returned matching string/false/enum values. Native session permission suppressed repeat approval. Client permanent-response encoding persisted across fresh real server processes. Required/default/optional/quit and unsupported-schema behavior tested. Native identity verification remains separate. |
| Verify tool-question presentation | Investigate | Earlier handler was schema-based. Capture a real CLI question flow with an owned provider/tool fixture. |

No external publication, account reconfiguration, paid requests, or mutation of
pre-existing threads is part of acceptance. Use isolated homes, loopback
providers, owned sessions and explicit event-injection labels where the test
proves frontend rendering rather than the real backend trigger.
