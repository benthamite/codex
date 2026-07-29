"""Capture raw app-server JSON-RPC items for ground-truth comparison.

Drives `codex app-server` directly through the same handshake codex.el uses
(initialize -> thread/start -> turn/start), auto-approves any approval
requests, and dumps the item/completed payloads (and plan updates) the server
emits.  Use this to learn the exact data shape codex.el must render, so the
renderer is built against real payloads rather than guessed ones.

Usage:
    python3 capture_protocol.py "PROMPT" [ITEM_TYPE]

ITEM_TYPE filters item/completed payloads (default: all). Examples:
    commandExecution  fileChange  agentMessage  reasoning  mcpToolCall

Env:
    CGT_DIR      working dir for the thread (default: /tmp/codex-gt)
    CGT_SANDBOX  sandbox mode (default: workspace-write)
    CGT_TURN_TIMEOUT seconds to wait for turn completion (default: 90)
"""
import subprocess, json, threading, sys, os, time

CWD = os.environ.get("CGT_DIR", "/tmp/codex-gt")
os.makedirs(CWD, exist_ok=True)
prompt = sys.argv[1] if len(sys.argv) > 1 else "Say hello, then stop."
want = sys.argv[2] if len(sys.argv) > 2 else None
# CGT_TRACE=1 echoes every inbound method to stderr as it arrives, with the
# params of server->client requests. Use it to capture the reference payload for
# a method codex-app-server.el does not handle yet: the item/completed dump
# below only shows finished items, so it cannot show you a request shape.
TRACE = os.environ.get("CGT_TRACE") == "1"
# Approval policy for the thread and turn. Defaults to "never", which is right
# for capturing ordinary item payloads. Set it to "on-request" or "untrusted"
# (with CGT_SANDBOX=read-only) to make the server actually ask, which is the
# only way to capture an approval request's shape.
APPROVAL = os.environ.get("CGT_APPROVAL", "never")
# CGT_TRACE_ONLY is a comma-separated method list. Tracing just the methods you
# care about also prints their params, including for notifications, which is how
# you capture the payload a new renderer must be written against.
TRACE_ONLY = ([m.strip() for m in os.environ["CGT_TRACE_ONLY"].split(",")]
              if os.environ.get("CGT_TRACE_ONLY") else None)
# CGT_EXTRA is a JSON array of {"method":..., "params":...} sent after the turn
# finishes, with responses traced. One session can then capture several
# request/response methods instead of one session each. "{threadId}" anywhere in
# a params string is replaced with the live thread id.
EXTRA = json.loads(os.environ["CGT_EXTRA"]) if os.environ.get("CGT_EXTRA") else []
# CGT_CODEX_ARGS is passed through to `codex app-server`, space-separated. Use it
# with `-c` overrides to add a config only for the capture, rather than editing
# ~/.codex/config.toml. Registering elicit_server.py this way is how an
# elicitation can be provoked without changing the user's real configuration.
CODEX_ARGS = (os.environ["CGT_CODEX_ARGS"].split()
              if os.environ.get("CGT_CODEX_ARGS") else [])
# Traced responses are truncated so one huge reply does not bury the log, but
# the default silently cut a plugin list mid-object and made it unparseable.
# Raise it with CGT_TRACE_MAX when you need the whole thing.
TRACE_MAX = int(os.environ.get("CGT_TRACE_MAX", "4000"))
TURN_TIMEOUT = float(os.environ.get("CGT_TURN_TIMEOUT", "90"))

p = subprocess.Popen(["codex", "app-server", *CODEX_ARGS], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     cwd=CWD, bufsize=1, text=True)
_id = [0]


def send(method, params):
    _id[0] += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": _id[0],
                              "method": method, "params": params}) + "\n")
    p.stdin.flush()


def reply(rid, result):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid,
                              "result": result}) + "\n")
    p.stdin.flush()


items = []; plans = []; tid = [None]; done = threading.Event()


def reader():
    for line in p.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except Exception:
            continue
        meth = m.get("method")
        if TRACE and meth is None and ("result" in m or "error" in m):
            print(f"[trace] RESPONSE id={m.get('id')}", file=sys.stderr)
            body = m.get("result") if "result" in m else m.get("error")
            print(json.dumps(body, indent=2)[:TRACE_MAX], file=sys.stderr)
        if TRACE and meth and (TRACE_ONLY is None or meth in TRACE_ONLY):
            kind = "REQUEST " if "id" in m else "notify  "
            print(f"[trace] {kind}{meth}", file=sys.stderr)
            if "id" in m or TRACE_ONLY:
                print(json.dumps(m.get("params"), indent=2), file=sys.stderr)
        if meth == "thread/started":
            pr = m["params"]
            tid[0] = (pr.get("thread") or {}).get("id") or pr.get("threadId")
        if meth and "approval" in meth.lower() and "id" in m:
            reply(m["id"], {"decision": "approved"})
        if meth == "turn/plan/updated":
            plans.append(m["params"])
        if meth == "item/completed":
            it = m["params"].get("item", {})
            if want is None or it.get("type") == want:
                items.append(it)
        if meth == "turn/completed":
            done.set()


threading.Thread(target=reader, daemon=True).start()
send("initialize", {"clientInfo": {"name": "cap", "title": "cap",
                                   "version": "0"},
                    "capabilities": {"experimentalApi": True,
                                     "requestAttestation": False}})
time.sleep(1)
send("thread/start", {"cwd": CWD, "approvalPolicy": APPROVAL,
                      "sandbox": os.environ.get("CGT_SANDBOX",
                                                "workspace-write")})
time.sleep(2)
if not tid[0]:
    print("NO THREAD ID", file=sys.stderr); sys.exit(1)
send("turn/start", {"threadId": tid[0],
                    "input": [{"type": "text", "text": prompt}],
                    "cwd": CWD, "approvalPolicy": APPROVAL})
if not done.wait(timeout=TURN_TIMEOUT):
    p.terminate()
    print(f"Turn timed out after {TURN_TIMEOUT:g} seconds", file=sys.stderr)
    sys.exit(1)
for call in EXTRA:
    params = json.loads(json.dumps(call.get("params", {}))
                        .replace("{threadId}", tid[0] or ""))
    print(f"[trace] SENDING {call['method']}", file=sys.stderr)
    send(call["method"], params)
    time.sleep(float(os.environ.get("CGT_EXTRA_WAIT", "4")))
print(json.dumps({"items": items, "plans": plans}, indent=2))
