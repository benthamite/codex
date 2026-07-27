"""Report app-server protocol methods codex-app-server.el does not handle.

codex-app-server.el reimplements the Codex client instead of hosting the CLI's
own TUI, so it inherits nothing when Codex ships a feature. Every new protocol
method is a feature that exists in Codex and silently does not exist here. This
script makes that visible: it asks the installed CLI for its protocol schema,
extracts the method surface, and diffs it against a reviewed baseline.

This finds CANDIDATES, not parity. Appearing in the schema says a method exists,
not what the CLI does with it, and a method counted as handled here may still be
rendered wrongly. Implementing anything it surfaces still means capturing the
CLI's real behavior first with codex_gt.py and capture_protocol.py, per the
repo's one rule.

Usage:
    python3 protocol_coverage.py            # report against the baseline
    python3 protocol_coverage.py --update   # rewrite baseline, keeping decisions

Exit status is 1 when the protocol has methods the baseline has never seen, so
the check can gate a Makefile target after a Codex upgrade.

The baseline records a decision per method, so the report stays small. Set a
method's "status" by hand in protocol-baseline.json:

    handled         codex-app-server.el implements it (verified automatically)
    wont-implement  deliberately skipped; give a "note" saying why
    todo            wanted, not built yet
    unreviewed      never triaged; everything starts here
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CLIENT = os.path.join(REPO, "codex-app-server.el")
BASELINE = os.path.join(HERE, "protocol-baseline.json")
SCHEMA_FILES = (
    "ClientRequest.json",
    "ClientNotification.json",
    "ServerRequest.json",
    "ServerNotification.json",
)


def codex_version():
    """Return the installed Codex CLI version string."""
    out = subprocess.run(["codex", "--version"], capture_output=True, text=True)
    return out.stdout.strip() or "unknown"


def generate_schema(outdir):
    """Write the app-server JSON schema for the installed CLI into OUTDIR."""
    subprocess.run(
        ["codex", "app-server", "generate-json-schema", "--out", outdir],
        check=True, capture_output=True, text=True,
    )


def schema_methods(outdir):
    """Return every JSON-RPC method name declared by the schema in OUTDIR."""
    found = set()

    def walk(node):
        if isinstance(node, dict):
            title = node.get("title")
            if isinstance(title, str) and title.endswith("Method"):
                found.update(x for x in node.get("enum", []) if isinstance(x, str))
            props = node.get("properties")
            if isinstance(props, dict) and isinstance(props.get("method"), dict):
                enum = props["method"].get("enum", [])
                found.update(x for x in enum if isinstance(x, str))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    for name in SCHEMA_FILES:
        path = os.path.join(outdir, name)
        if os.path.exists(path):
            with open(path) as handle:
                walk(json.load(handle))
    return found


def handled_methods(methods):
    """Return the subset of METHODS named in codex-app-server.el's code.

    Comment lines are stripped first, so a method merely mentioned in prose
    does not count as implemented. This is a name match, not a behavior check:
    it cannot tell a correct handler from a stub.
    """
    with open(CLIENT) as handle:
        code = "\n".join(
            line for line in handle if not re.match(r"\s*;", line)
        )
    return {m for m in methods if f'"{m}"' in code}


def load_baseline():
    """Return the recorded baseline, or an empty one when absent."""
    if not os.path.exists(BASELINE):
        return {"codex_version": None, "methods": {}}
    with open(BASELINE) as handle:
        return json.load(handle)


def write_baseline(version, methods, handled, previous):
    """Write the baseline for METHODS, preserving decisions in PREVIOUS."""
    old = previous.get("methods", {})
    entries = {}
    for name in sorted(methods):
        prior = old.get(name, {})
        status = "handled" if name in handled else prior.get("status", "unreviewed")
        if status == "handled" and name not in handled:
            status = "unreviewed"
        entry = {"status": status}
        if prior.get("note"):
            entry["note"] = prior["note"]
        entries[name] = entry
    payload = {"codex_version": version, "methods": entries}
    with open(BASELINE, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return payload


def group(names):
    """Return NAMES grouped by their leading protocol namespace."""
    out = {}
    for name in sorted(names):
        out.setdefault(name.split("/")[0], []).append(name)
    return out


def report(version, methods, handled, baseline):
    """Print the coverage report and return the process exit status."""
    known = set(baseline.get("methods", {}))
    new = methods - known
    gone = known - methods
    recorded = baseline.get("methods", {})
    regressed = {
        n for n, e in recorded.items()
        if e.get("status") == "handled" and n in methods and n not in handled
    }
    unreviewed = {
        n for n, e in recorded.items()
        if e.get("status") == "unreviewed" and n in methods
    }
    wont = {n for n, e in recorded.items() if e.get("status") == "wont-implement"}
    todo = {n for n, e in recorded.items() if e.get("status") == "todo"}

    print(f"codex {version}   baseline {baseline.get('codex_version') or '(none)'}")
    print(f"protocol methods: {len(methods)}   handled: {len(handled)}")
    print(f"decisions: {len(wont)} won't-implement, {len(todo)} todo, "
          f"{len(unreviewed)} unreviewed")

    if regressed:
        print(f"\nREGRESSED -- baseline says handled, source no longer names them "
              f"({len(regressed)}):")
        for name in sorted(regressed):
            print(f"  {name}")

    if gone:
        print(f"\nREMOVED from the protocol ({len(gone)}):")
        for name in sorted(gone):
            print(f"  {name}")

    if new:
        print(f"\nNEW since the baseline ({len(new)}) -- triage these:")
        for namespace, names in group(new).items():
            print(f"  {namespace}/")
            for name in names:
                mark = "handled" if name in handled else "not handled"
                print(f"    {name}  [{mark}]")

    if todo:
        print(f"\nWanted, not built ({len(todo)}):")
        for name in sorted(todo):
            print(f"  {name}")

    if not (new or gone or regressed):
        print("\nNo protocol changes since the baseline.")

    if unreviewed:
        print(f"\n{len(unreviewed)} methods are still unreviewed. Set each to "
              f"handled, todo, or wont-implement in\n{BASELINE}")

    return 1 if (new or gone or regressed) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true",
                        help="rewrite the baseline, keeping existing decisions")
    args = parser.parse_args()

    version = codex_version()
    with tempfile.TemporaryDirectory() as outdir:
        generate_schema(outdir)
        methods = schema_methods(outdir)
    if not methods:
        sys.exit("no methods found in the generated schema")
    handled = handled_methods(methods)
    baseline = load_baseline()

    if args.update:
        payload = write_baseline(version, methods, handled, baseline)
        counts = {}
        for entry in payload["methods"].values():
            counts[entry["status"]] = counts.get(entry["status"], 0) + 1
        print(f"wrote {BASELINE}")
        print(f"codex {version}: {len(payload['methods'])} methods " +
              ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
        return 0
    return report(version, methods, handled, baseline)


if __name__ == "__main__":
    sys.exit(main())
