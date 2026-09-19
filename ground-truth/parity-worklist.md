# Remaining terminal-UI parity work

This tracks behavior rather than method-name coverage. The protocol baseline
records method decisions; an entry marked handled there can still have a
behavioral gap here. Evidence is for installed Codex 0.155.1.

| Work | Decision | Evidence needed |
| --- | --- | --- |
| Render authentication recovery and strict-review notices | Done | Controlled notifications rendered in actual TUI/Eat and native Emacs with matching text and prefixes; thread filtering tested. Real credential recovery and review triggering were not exercised. |
| Select server-discovered Plan/Default modes | Do | Capture `/plan`, discover presets, verify effective settings and subsequent turn behavior in isolated sessions. |
| Answer external-clock requests | Do | Enable external clock in an isolated server; observe the real callback and reminder reaching a loopback model provider. |
| Match `/memories` controls | Do | Capture use/generate/reset settings, persist effective config and current-thread generation; test reset only in an owned disposable memory store. |
| Preserve final realtime transcript text | Do | Compare final-only, corrected-final, and delta-plus-final transcript rendering against actual CLI behavior. |
| Hydrate persisted realtime history | Defer: server unsupported | Actual 0.155.1 server resumed an owned mixed-history fixture and served ordinary turn pages, but `thread/timeline/list` returned -32601, “not supported yet”. Revisit after server support exists. |
| Branch before an earlier prompt for editing | Investigate | Capture the current source-preserving CLI backtracking flow; do not substitute destructive in-place revert. |
| Support native user verification | Defer pending safe capture | The CLI requests native identity proof during some MCP elicitations. Exercise cancellation/error paths with isolated requests; a real proof may require the user's biometric interaction. |
| Complete MCP elicitation choices and forms | Investigate | Earlier baseline lacks session/permanent allow choices and form data. Capture exact response metadata and form types using an owned probe server. |
| Verify tool-question presentation | Investigate | Earlier handler was schema-based. Capture a real CLI question flow with an owned provider/tool fixture. |

No external publication, account reconfiguration, paid requests, or mutation of
pre-existing threads is part of acceptance. Use isolated homes, loopback
providers, owned sessions and explicit event-injection labels where the test
proves frontend rendering rather than the real backend trigger.
