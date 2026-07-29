# Ground-truth harness

Tools for verifying codex.el against the **real Codex CLI** instead of against
codex.el's own code. See the repo `CLAUDE.md` for the rule these enforce: a
parity claim is only done when the CLI's actual user-visible behavior was
captured first and codex.el's output was diffed against it.

## `codex_gt.py` — what the user SEES

Drives the real `codex` TUI under a pty and returns the rendered screen.

```bash
python3 codex_gt.py wait:2 "send:Read README.md and quote its first line." key:enter wait:20
```

Resume an existing CLI session by id:

```bash
python3 codex_gt.py --resume SESSION_ID wait:2
```

Set the capture directory and terminal size explicitly:

```bash
python3 codex_gt.py --cwd /tmp/codex-gt --cols 120 --rows 40 wait:3
```

Steps: `wait:SECONDS`, `send:TEXT`, `key:enter|tab|esc|up|down|bs|ctrlc|ctrlv`.
Env: `CGT_APPROVAL` (default `never`), `CGT_SANDBOX` (default `read-only`;
use `workspace-write` for edits), `CGT_DIR` (default `/tmp/codex-gt`, must be
a git repo with trust pre-handled).

This is the reference image. codex.el's buffer must match this.

`CGT_FRAMES=SECONDS` records a frame that often while waiting and prints every
distinct screen, not just the last. Transient states — an approval prompt that
is answered automatically, a two-second review pause, a spinner — are invisible
to a single final screenshot, and guessing a wait long enough to land inside one
costs a session per attempt.

Note that `CGT_APPROVAL` defaults to `never`, which makes the CLI *auto-deny*
approval requests before any prompt renders. Capturing an approval prompt needs
`CGT_APPROVAL=on-request` as well as whatever config the prompt itself requires:

```bash
CGT_FRAMES=0.5 CGT_SANDBOX=read-only CGT_APPROVAL=on-request \
  CGT_CODEX_ARGS="-c approvals_reviewer=user -c features.request_permissions_tool=true" \
  python3 codex_gt.py --cwd /tmp/codex-gt wait:6 key:esc wait:2 \
    "send:Write DONE into a new file called perm.txt." key:enter wait:34
```

## `capture_protocol.py` — the data codex.el RENDERS from

Drives `codex app-server` through codex.el's handshake and dumps the raw
`item/completed` payloads (and plan updates).

```bash
python3 capture_protocol.py "Change four to FOUR on line 4 of lines.txt" fileChange
```

Use this to build renderers against real payload shapes (e.g. the unified-diff
text in a `fileChange`, the `commandActions` of a read), not guessed ones.

`CGT_TRACE=1` echoes every inbound method to stderr as it arrives, printing the
params of server→client requests. The `item/completed` dump only shows finished
items, so tracing is the only way to capture a *request* shape — which is what
you need for any method the client does not handle yet.

`CGT_TURN_TIMEOUT` sets how many seconds to wait for `turn/completed` (default
90). A timeout exits unsuccessfully instead of printing a partial capture as
though the turn had completed.

`CGT_APPROVAL` sets the approval policy (default `never`). The server only sends
approval requests when it has to ask, so pair `CGT_APPROVAL=untrusted` with
`CGT_SANDBOX=read-only` and a prompt that needs a write:

```bash
CGT_TRACE=1 CGT_SANDBOX=read-only CGT_APPROVAL=untrusted \
  python3 capture_protocol.py "Append DONE to lines.txt with a shell command."
```

Note that a scenario does not always reach the method you expected: the above
escalates through `item/commandExecution/requestApproval`, not through
`item/permissions/requestApproval`. Finding a trigger is usually the slow part
of adding support for a method.

`CGT_EXTRA` sends arbitrary requests once the turn finishes and traces the
responses, so one session can capture several request/response methods instead
of one session each. `{threadId}` in params is replaced with the live thread id;
`CGT_EXTRA_WAIT` sets the pause between calls (default 4s).

```bash
CGT_TRACE=1 CGT_EXTRA='[{"method":"thread/read","params":{"threadId":"{threadId}"}}]' \
  python3 capture_protocol.py "Say ok."
```

## `protocol_coverage.py` — what Codex offers that codex.el ignores

`codex-app-server.el` reimplements the client rather than hosting the CLI's own
TUI, so unlike `codex-eat.el` and `codex-vterm.el` it inherits nothing when
Codex ships a feature. A new protocol method is a feature that exists in Codex
and silently does not exist here. This script asks the installed CLI for its
protocol schema, extracts every JSON-RPC method, and diffs that against a
reviewed baseline in `protocol-baseline.json`.

```bash
make protocol-coverage          # or: python3 ground-truth/protocol_coverage.py
python3 ground-truth/protocol_coverage.py --update   # after triaging
```

Run it after every Codex upgrade. It exits non-zero when the protocol gained or
lost methods, so it can gate a target.

This finds **candidates, not parity**. A method in the schema tells you it
exists, not what the CLI does with it, and a method counted as handled may still
render wrongly — the check is a name match against the source. Anything it
surfaces still goes through the workflow below before you can claim it works.

Each method carries a decision in the baseline, so the report stays short. Set
`status` by hand to `handled` (detected automatically), `wont-implement` (with a
`note` saying why), or `todo`. Everything starts as `unreviewed`; triaging those
once means later runs show only what actually changed.

## `elicit_server.py` — provoking an MCP elicitation

No configured MCP server asks the user anything during an ordinary turn, so
`mcpServer/elicitation/request` cannot be captured without a server that
provokes one. This is a minimal MCP server whose only tool elicits input.

Register it for the capture only, via `CGT_CODEX_ARGS`, rather than editing
`~/.codex/config.toml`. Both capture scripts pass that variable through to the
CLI, so the same override works for the protocol payload and the TUI reference:

```bash
S=$PWD/elicit_server.py
OVERRIDE="-c mcp_servers.elicit_probe={command=\"python3\",args=[\"$S\"]}"

CGT_TRACE=1 CGT_CODEX_ARGS="$OVERRIDE" \
  python3 capture_protocol.py "Call the elicit_probe ask_colour tool."

CGT_CODEX_ARGS="$OVERRIDE" \
  python3 codex_gt.py --cwd /tmp/codex-gt wait:6 key:esc wait:2 \
    "send:Call the elicit_probe ask_colour tool." key:enter wait:24
```

Keep override values free of spaces: `CGT_CODEX_ARGS` is split naively.

## Workflow

1. `codex_gt.py` → capture what the CLI displays for the interaction.
2. `capture_protocol.py` → capture the payloads codex.el will receive.
3. Implement the codex.el renderer/behavior against (2).
4. Reproduce the interaction in codex.el and diff its output against (1).
5. Only claim parity when 4 matches.

## Setup notes

- This directory is tracked. It holds only source: captures go to `CGT_DIR`
  (default `/tmp/codex-gt`), never here, and `protocol-baseline.json` is a
  reviewed decision record that is meant to be versioned. The repo's one rule
  requires this harness, so a clone without it cannot verify a parity claim.
- Requires `pyte` (`pip install pyte`) and the `codex` CLI on PATH.
- `CGT_DIR` must be an initialized git repo; on first run the CLI shows a trust
  prompt which `codex_gt.py` answers with Enter.
- Image paste: put a PNG on the clipboard first, then use a `key:ctrlv` step.
- `elicit_server.py` needs the `mcp` package (`pip install mcp`).
