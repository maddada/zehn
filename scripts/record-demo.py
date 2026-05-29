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


def make_fake_agents(home):
    """Stub agent CLIs so a fork actually lands and prints a banner in the demo
    instead of failing (the real claude/codex/... aren't on the sandbox PATH)."""
    binp = f"{home}/bin"
    os.makedirs(binp, exist_ok=True)
    colors = {"claude": "38;2;218;119;86", "codex": "38;2;16;163;127",
              "pi": "38;2;136;192;208", "opencode": "38;2;207;206;205"}
    for name, color in colors.items():
        p = f"{binp}/{name}"
        with open(p, "w") as f:
            f.write("#!/bin/sh\n")
            f.write(f'printf "\\033[{color}m{name}\\033[0m \\033[90mnew session\\033[0m\\n"\n')
            f.write('printf "\\033[90m> \\033[0m%s\\n" "$1"\n')
            f.write("sleep 1.2\n")
        os.chmod(p, 0o755)
    return binp


seed_history(HOME)
FAKE_BIN = make_fake_agents(HOME)

env = dict(os.environ)
env["HOME"] = HOME
env["TERM"] = "xterm-256color"
env["COLORTERM"] = "truecolor"
env["PATH"] = FAKE_BIN + ":" + env.get("PATH", "")  # so a fork finds the stub agents

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
type_str("deploy"); drain(1.0)      # fuzzy filter across agents
os.write(fd, CTRL_F); drain(0.9)    # ★ favorite the top match
os.write(fd, DOWN); drain(0.4)
os.write(fd, CTRL_F); drain(0.9)    # favorite another
for _ in range(6): os.write(fd, b"\x7f")  # clear the query
drain(1.5)                          # ★ favorites are pinned to the top of the list
os.write(fd, CTRL_O); drain(1.6)    # ^o fork: pick an agent to reuse the prompt in
os.write(fd, b"2"); drain(2.0)      # 2 -> start a fresh CODEX session with this prompt

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
