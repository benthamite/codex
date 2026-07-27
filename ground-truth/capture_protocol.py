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

p = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE,
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
        if TRACE and meth:
            kind = "REQUEST " if "id" in m else "notify  "
            print(f"[trace] {kind}{meth}", file=sys.stderr)
            if "id" in m:
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
done.wait(timeout=90)
print(json.dumps({"items": items, "plans": plans}, indent=2))
