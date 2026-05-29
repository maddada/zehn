#!/usr/bin/env python3
"""Drive zehn in a pty with scripted keystrokes, emit an asciicast v2 file.

Self-seeds a small, curated history under a throwaway HOME so the recording is
reproducible and never leaks real prompts. Demonstrates the picker plus the
favorite / copy / fork keys.

The fork step launches the REAL codex CLI (so the demo shows codex's actual
TUI, not a stub). Reproducing it therefore needs `codex` on PATH and signed in;
CODEX_HOME is pointed at the user's real ~/.codex while zehn reads the seeded
HOME. codex runs for a few seconds then is killed, so it makes no changes.
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
# zehn reads the seeded history under the throwaway HOME, but a fork launches the
# REAL codex — point CODEX_HOME at the user's actual config so it keeps its auth.
env["CODEX_HOME"] = os.path.expanduser("~/.codex")

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


CTRL_C, CTRL_F, CTRL_O, CTRL_Y, ESC, ENTER, DOWN = (
    b"\x03", b"\x06", b"\x0f", b"\x19", b"\x1b", b"\r", b"\x1b[B")

# --- demo script ---
drain(1.3)                          # show the full cross-agent list
type_str("deploy"); drain(1.0)      # fuzzy filter across agents
os.write(fd, CTRL_F); drain(0.9)    # ★ favorite the top match
os.write(fd, DOWN); drain(0.4)
os.write(fd, CTRL_F); drain(0.9)    # favorite another
for _ in range(6): os.write(fd, b"\x7f")  # clear the query
drain(1.5)                          # ★ favorites are pinned to the top of the list
os.write(fd, CTRL_O); drain(1.6)    # ^o fork: pick an agent to reuse the prompt in
os.write(fd, b"2"); drain(2.2)      # 2 -> launch the real codex with this prompt
os.write(fd, ENTER); drain(3.5)     # trust the dir -> codex opens with the forked prompt
os.write(fd, CTRL_C); drain(0.4)    # quit codex
os.write(fd, CTRL_C); drain(0.6)

# Tear down the whole tree (recorder -> zehn -> codex); codex may not exit on its
# own, so kill the process group rather than block forever on waitpid.
import signal
try:
    os.killpg(os.getpgid(pid), signal.SIGTERM)
    time.sleep(0.3)
    os.killpg(os.getpgid(pid), signal.SIGKILL)
except Exception:
    pass
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
