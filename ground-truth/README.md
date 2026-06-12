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

## `capture_protocol.py` — the data codex.el RENDERS from

Drives `codex app-server` through codex.el's handshake and dumps the raw
`item/completed` payloads (and plan updates).

```bash
python3 capture_protocol.py "Change four to FOUR on line 4 of lines.txt" fileChange
```

Use this to build renderers against real payload shapes (e.g. the unified-diff
text in a `fileChange`, the `commandActions` of a read), not guessed ones.

## Workflow

1. `codex_gt.py` → capture what the CLI displays for the interaction.
2. `capture_protocol.py` → capture the payloads codex.el will receive.
3. Implement the codex.el renderer/behavior against (2).
4. Reproduce the interaction in codex.el and diff its output against (1).
5. Only claim parity when 4 matches.

## Setup notes

- Requires `pyte` (`pip install pyte`) and the `codex` CLI on PATH.
- `CGT_DIR` must be an initialized git repo; on first run the CLI shows a trust
  prompt which `codex_gt.py` answers with Enter.
- Image paste: put a PNG on the clipboard first, then use a `key:ctrlv` step.
