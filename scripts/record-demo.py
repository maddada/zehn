#!/usr/bin/env python3
"""Drive zehn in a pty with scripted keystrokes, emit an asciicast v2 file.

Self-seeds a small, curated history under a throwaway HOME so the recording is
reproducible and never leaks real prompts. Demonstrates the picker plus the
favorite / copy / fork keys.
"""
import os, pty, select, struct, fcntl, termios, time, json, sys, shutil

W, H = 100, 22
BIN = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/zehn"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/zehn-demo/demo.cast"
HOME = "/tmp/zehn-demo"


def seed_history(home):
    """Write a curated cross-agent history so the demo has realistic content."""
    shutil.rmtree(home, ignore_errors=True)  # fresh state (also clears favorites)

    claude = [
        "deploy the staging build to fly.io",
        "add JWT auth middleware to the API",
        "write a React hook for debounced search",
        "fix the flaky timeout in the deploy pipeline",
        "explain this borrow checker error",
        "set up a GitHub Actions release workflow",
        "refactor the auth module to use sessions",
        "add a dark mode toggle to the navbar",
    ]
    codex = [
        "optimize the SQL query for the dashboard",
        "generate unit tests for the parser",
        "deploy the worker to Cloud Run",
        "convert this callback code to async/await",
    ]
    pi = [
        "draft a migration plan for the new schema",
        "summarize the auth refactor for the PR",
    ]

    os.makedirs(f"{home}/.claude", exist_ok=True)
    os.makedirs(f"{home}/.codex", exist_ok=True)
    sess = f"{home}/.pi/agent/sessions/019e-demo"
    os.makedirs(sess, exist_ok=True)

    ts = 1748000000000
    with open(f"{home}/.claude/history.jsonl", "w") as f:
        for i, p in enumerate(claude):
            f.write(json.dumps({"display": p, "project": "~/work/app",
                                "sessionId": f"c{i}", "timestamp": ts + i * 1000}) + "\n")
    with open(f"{home}/.codex/history.jsonl", "w") as f:
        for i, p in enumerate(codex):
            f.write(json.dumps({"session_id": f"x{i}", "ts": 1748000000 + i,
                                "text": p}) + "\n")
    with open(f"{sess}/session.jsonl", "w") as f:
        f.write(json.dumps({"type": "session", "version": 3,
                            "id": "019e-demo", "cwd": "~/work/app"}) + "\n")
        for p in pi:
            f.write(json.dumps({"type": "message", "message": {
                "role": "user", "content": [{"type": "text", "text": p}]}}) + "\n")


seed_history(HOME)

env = dict(os.environ)
env["HOME"] = HOME
env["TERM"] = "xterm-256color"
env["COLORTERM"] = "truecolor"

pid, fd = pty.fork()
if pid == 0:
    os.execve(BIN, [BIN], env)  # interactive mode (favorites persist, overlays show)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", H, W, 0, 0))

start = time.time()
events = []


def drain(duration):
    end = time.time() + duration
    while True:
        remaining = end - time.time()
        if remaining <= 0:
            break
        r, _, _ = select.select([fd], [], [], remaining)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            events.append([round(time.time() - start, 3), "o",
                           data.decode("utf-8", "replace")])
    return True


def type_str(s, cps=0.07):
    for ch in s:
        os.write(fd, ch.encode())
        drain(cps)


CTRL_F, CTRL_O, CTRL_Y, ESC, DOWN = b"\x06", b"\x0f", b"\x19", b"\x1b", b"\x1b[B"

# --- demo script ---
drain(1.3)                          # show the full cross-agent list
type_str("deploy"); drain(1.1)      # fuzzy filter across agents
os.write(fd, CTRL_F); drain(1.0)    # ★ favorite the top match
os.write(fd, DOWN); drain(0.45)
os.write(fd, CTRL_F); drain(1.0)    # favorite another
for _ in range(6): os.write(fd, b"\x7f")  # clear the query
drain(1.6)                          # ★ favorites are pinned to the top of the list
os.write(fd, CTRL_O); drain(1.5)    # fork: pick an agent to reuse the prompt in
os.write(fd, ESC); drain(0.8)       # cancel the fork picker
os.write(fd, CTRL_Y); drain(1.1)    # copy the prompt to the clipboard, exits

try:
    os.waitpid(pid, 0)
except Exception:
    pass

header = {"version": 2, "width": W, "height": H,
          "timestamp": int(start), "env": {"TERM": "xterm-256color"}}
with open(OUT, "w") as f:
    f.write(json.dumps(header) + "\n")
    for e in events:
        f.write(json.dumps(e) + "\n")
print(f"wrote {OUT} ({len(events)} events, {events[-1][0] if events else 0}s)")
