#!/usr/bin/env python3
"""Drive zehn in a pty with scripted keystrokes, emit an asciicast v2 file."""
import os, pty, select, struct, fcntl, termios, time, json, sys

W, H = 100, 20
BIN = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/zehn"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/zehn-demo/demo.cast"

env = dict(os.environ)
env["HOME"] = "/tmp/zehn-demo"
env["TERM"] = "xterm-256color"
env["COLORTERM"] = "truecolor"

pid, fd = pty.fork()
if pid == 0:
    os.execve(BIN, [BIN, "--print"], env)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", H, W, 0, 0))

start = time.time()
events = []

def drain(duration):
    """Read output for `duration` seconds, recording timed events."""
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
            events.append([round(time.time() - start, 3), "o", data.decode("utf-8", "replace")])
    return True

def type_str(s, cps=0.06):
    for ch in s:
        os.write(fd, ch.encode())
        drain(cps)

# --- demo script ---
drain(1.2)                      # show full list
type_str("deploy"); drain(1.3)  # fuzzy filter across agents
for _ in range(3):              # browse results, preview updates
    os.write(fd, b"\x1b[B"); drain(0.55)
drain(0.6)
for _ in range(6): os.write(fd, b"\x7f")  # clear query
drain(1.0)
type_str("react"); drain(1.3)
os.write(fd, b"\x1b[B"); drain(0.7)
drain(0.6)
for _ in range(5): os.write(fd, b"\x7f")
drain(0.8)
type_str("auth"); drain(1.3)
os.write(fd, b"\r"); drain(0.8)  # select -> prints prompt, exits

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
