"""Capture the real Codex CLI's rendered screen for ground-truth comparison.

Drives the actual `codex` TUI under a pty, answers the terminal-capability
queries it sends on startup, and renders its output with pyte so you get back
the text the user would SEE on screen.  Use this to learn what the CLI displays
for a given interaction, then compare codex.el's buffer against it.

Usage:
    python3 codex_gt.py wait:2 "send:hello" key:enter wait:15
    python3 codex_gt.py --resume SESSION_ID wait:2

Steps:
    wait:SECONDS     drain output for SECONDS
    send:TEXT        type TEXT (no trailing newline)
    key:NAME         press a key: enter tab esc up down bs ctrlc ctrlv

Env:
    CGT_APPROVAL     codex approval policy (default: never).
    CGT_SANDBOX      codex sandbox mode (default: read-only); use
                     workspace-write to allow file edits.
    CGT_DIR          working directory (default: /tmp/codex-gt).

For an image-paste capture: put a PNG on the clipboard first (macOS:
`osascript -e 'set the clipboard to (read (POSIX file "/path/x.png") as ...)'`
or a tool like pngpaste in reverse), then run with a `key:ctrlv` step.
"""
import argparse, os, pty, time, select, struct, fcntl, termios, sys, pyte


def parse_args(argv, env=None):
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(
        description="Capture the real Codex CLI's rendered screen."
    )
    parser.add_argument("--resume", metavar="SESSION_ID")
    parser.add_argument("--cwd", default=env.get("CGT_DIR", "/tmp/codex-gt"))
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("scenario", nargs="*")
    return parser.parse_args(argv)


def build_codex_argv(config=None, approval=None, sandbox=None, env=None):
    env = os.environ if env is None else env
    approval = env.get("CGT_APPROVAL", "never") if approval is None else approval
    sandbox = env.get("CGT_SANDBOX", "read-only") if sandbox is None else sandbox
    # CGT_CODEX_ARGS is passed through, space-separated, so a capture can add
    # `-c` config overrides without editing ~/.codex/config.toml. Keep override
    # values free of spaces, since the split is naive.
    extra = env.get("CGT_CODEX_ARGS", "").split()
    resume = getattr(config, "resume", None)
    if resume:
        return ["codex", "resume", "-a", approval, "-s", sandbox,
                "--no-alt-screen", *extra, resume]
    return ["codex", "-a", approval, "-s", sandbox, "--no-alt-screen", *extra]


def run(scenario, cols=120, rows=40, cwd=None, resume=None):
    os.chdir(cwd or os.environ.get("CGT_DIR", "/tmp/codex-gt"))
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        config = argparse.Namespace(resume=resume)
        os.execvp("codex", build_codex_argv(config))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    sc = pyte.Screen(cols, rows); st = pyte.ByteStream(sc)
    acc = bytearray(); answered = {}

    def respond():
        b = bytes(acc)
        for pat, resp, tag in [
            (b"\x1b[6n", b"\x1b[1;1R", "6n"),
            (b"\x1b]10;?", b"\x1b]10;rgb:0000/0000/0000\x1b\\", "fg"),
            (b"\x1b]11;?", b"\x1b]11;rgb:ffff/ffff/ffff\x1b\\", "bg"),
            (b"\x1b[c", b"\x1b[?1;2c", "da"),
            (b"\x1b[?u", b"\x1b[?0u", "k"),
        ]:
            n = b.count(pat); s = answered.get(tag, 0)
            while s < n:
                os.write(fd, resp); s += 1
            answered[tag] = s

    def disp():
        return "\n".join(l.rstrip() for l in sc.display)

    # CGT_FRAMES=SECONDS records a frame that often while waiting, keeping every
    # distinct screen instead of only the last. Transient states -- a two-second
    # approval-review pause, a spinner, a prompt that is answered automatically
    # -- are invisible to a single final screenshot, and guessing a wait long
    # enough to land inside one wastes a session per attempt.
    frame_every = float(os.environ.get("CGT_FRAMES", "0") or 0)
    frames = []

    def snap():
        if frame_every:
            cur = disp()
            if not frames or frames[-1] != cur:
                frames.append(cur)

    def drain(t):
        end = time.time() + t
        next_frame = time.time() + frame_every if frame_every else None
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.15)
            if r:
                try:
                    d = os.read(fd, 65536)
                except OSError:
                    return
                if not d:
                    return
                acc.extend(d); st.feed(d); respond()
            if next_frame and time.time() >= next_frame:
                snap(); next_frame = time.time() + frame_every

    keys = {"tab": b"\t", "enter": b"\r", "esc": b"\x1b", "up": b"\x1b[A",
            "down": b"\x1b[B", "bs": b"\x7f", "ctrlc": b"\x03",
            "ctrlv": b"\x16"}
    drain(5)
    if "trust" in disp().lower():
        os.write(fd, b"\r"); drain(3)
    for step in scenario:
        k, _, v = step.partition(":")
        if k == "wait":
            drain(float(v))
        elif k == "send":
            for ch in v.encode():
                os.write(fd, bytes([ch])); time.sleep(0.02)
            drain(0.3)
        elif k == "key":
            os.write(fd, keys[v]); drain(0.3)
    drain(1.5)
    snap()
    out = disp()
    if frame_every and frames:
        out = "\n".join(
            f"===== frame {i + 1}/{len(frames)}\n{f}"
            for i, f in enumerate(frames))
    try:
        os.write(fd, b"\x03"); time.sleep(0.2); os.write(fd, b"\x03")
    except OSError:
        pass
    return out


def main(argv):
    config = parse_args(argv)
    scenario = config.scenario if config.scenario else ["wait:3"]
    print(run(scenario, cols=config.cols, rows=config.rows,
              cwd=config.cwd, resume=config.resume))


if __name__ == "__main__":
    main(sys.argv[1:])
