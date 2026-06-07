<div align="center">

# zehn

*ذهن — "the mind"*

Find any prompt you have ever typed to an AI coding agent, then drop back into that session.

<img src="assets/demo.gif" width="100%" alt="zehn searching across claude, codex, and pi histories">

[Install](#how-do-i-install-it) ·
[Usage](#how-do-i-use-it) ·
[Sources](#where-does-it-look) ·
[Matching](#how-matching-works)

![Zig](https://img.shields.io/badge/Zig-0.16-f7a41d?style=for-the-badge&logo=zig&logoColor=white)
![License](https://img.shields.io/badge/License-PolyForm%20Noncommercial-blue?style=for-the-badge)
![Platform](https://img.shields.io/badge/Linux-555?style=for-the-badge&logo=linux&logoColor=white)

<p>
  Works with
  <a href="https://www.anthropic.com/claude-code"><kbd><img src="https://www.google.com/s2/favicons?domain=claude.ai&sz=64" width="14" valign="middle" /> Claude Code</kbd></a> &nbsp;
  <a href="https://github.com/openai/codex"><kbd><img src="https://www.google.com/s2/favicons?domain=openai.com&sz=64" width="14" valign="middle" /> Codex</kbd></a> &nbsp;
  <a href="https://pi.dev"><kbd><img src="https://pi.dev/favicon.svg" width="14" valign="middle" /> pi</kbd></a> &nbsp;
  <a href="https://opencode.ai"><kbd><img src="https://www.google.com/s2/favicons?domain=opencode.ai&sz=64" width="14" valign="middle" /> opencode</kbd></a> &nbsp;
  <kbd>Cursor Agent</kbd> &nbsp;
  <kbd>Grok</kbd>
</p>

</div>

## What is this?

You use claude one day, codex the next, then pi, opencode, Cursor Agent, or Grok after that. A week later you want the thing you asked for back then, but you cannot remember which agent you said it to, let alone which project. So you go digging through six different history formats by hand.

zehn reads all of them at once. It pulls every prompt you have sent to claude, codex, pi, opencode, Cursor Agent, and Grok into a single fuzzy-searchable list. You type a few letters, find the prompt, hit Enter, and it puts you back in that exact session in the agent that owns it.

It is one small Zig binary with no runtime dependencies (sqlite3 is optional, and only for opencode). On my machine it reads and parses about 1,300 sessions in roughly 0.2 seconds.

## How do I install it?

One line, macOS or Linux:

```sh
bash <(curl -L https://al3rez.com/zehn)
```

It clones the repo, does a `ReleaseFast` build, and leaves the binary at `~/.local/bin/zehn`. If you don't already have [Zig 0.16+](https://ziglang.org/download/), it grabs it for you via `brew`/`pacman` when present, otherwise the official tarball from ziglang.org. Set `PREFIX` to install somewhere else (`PREFIX=/usr/local bash <(curl -L ...)`), or `NO_INSTALL_ZIG=1` to make it refuse rather than fetch Zig.

Already installed? Run this when you want to update:

```sh
zehn update
```

zehn does not check for updates automatically, so normal searches stay quiet and offline. The `zehn update` command checks GitHub master only when you run it.

Prefer to do it by hand? You'll need [Zig 0.16](https://ziglang.org/download/) or newer.

```sh
git clone https://github.com/al3rez/zehn && cd zehn
zig build -Doptimize=ReleaseFast --prefix ~/.local
```

Either way, make sure `~/.local/bin` is on your `PATH`. If you would rather not install it anywhere, the build also leaves a copy at `zig-out/bin/zehn`.

## How do I use it?

Just run it:

```sh
zehn
```

Type to filter. Use the arrow keys or `^p`/`^n` to move. Press Enter on a prompt and zehn `cd`s into that session's project directory and runs the agent's resume command for you. If the project folder is gone, it falls back to your current directory and tells you.

If you do not want it to launch anything, the other modes just print:

```sh
zehn --print     # print the prompt text of whatever you select
zehn --project   # print  agent <tab> project <tab> text
zehn --accept-all     # resume supported agents with permission-bypass flags
zehn --agent claude   # only show one agent: claude, codex, pi, opencode, cursor, or grok
zehn --opencode       # shorthand for --agent opencode
zehn --list      # dump everything, no UI
zehn update      # update to the latest master build
zehn --version
```

Results are grouped by last-active day by default, with the newest day first. Each result uses two content lines plus a spacer: the agent and matched prompt first, then the last-active time under the agent and the session title or session id under the prompt. Press `^d` to toggle day grouping on or off. In grouped mode, PageUp/PageDown jumps to the first session in the previous/next day group; terminals that report modified arrows can also use Ctrl-Up/Ctrl-Down.

Keys: type to filter, `↑`/`↓` or `^p`/`^n` to move, Enter to pick, Esc or `^c` to quit. Mouse hover selects a session, and click resumes it. Press `^t` for the agent picker, or `^r` for the project picker. The search box has the usual readline-ish editing: left/right, Ctrl-left/right, Ctrl-U, Ctrl-K, Ctrl-backspace, and Ctrl-delete.

Long prompts are a thing, especially if you use `/skill` blocks. Press Tab to focus the preview, PageUp/PageDown to scroll it, left/right to horizontally scroll the selected result, Ctrl-right/Ctrl-left to jump that result to the end/start, `W` to toggle wrapping, and `F` for a larger preview.

Some prompts are worth keeping around. Press `^f` to favorite the selected one — it
gets a `★` and floats to the top of every result list. Favorites live in
`$XDG_CONFIG_HOME/zehn/favorites` (or `~/.config/zehn/favorites`), keyed by a hash of
the prompt so the read-only history files are never touched.

You can also reuse a prompt somewhere other than its origin session. `^y` copies the
selected prompt to the clipboard (via `pbcopy`/`wl-copy`/`xclip`/`xsel`). `^o` forks it:
pick an agent (`1` claude, `2` codex, `3` pi, `4` opencode, `5` cursor, `6` grok) and zehn starts a fresh
session there seeded with that prompt — so a prompt you wrote to one agent can be fired
at another.

## Where does it look?

| Agent    | History location                                                    | Resume command                |
|----------|---------------------------------------------------------------------|-------------------------------|
| claude   | `~/.claude/history.jsonl`                                            | `claude --resume <id>`        |
| codex    | `~/.codex/history.jsonl` and `~/.codex/sessions/**/*.jsonl`          | `codex resume <id>`           |
| pi       | `~/.pi/agent/sessions/*/*.jsonl`                                    | `pi --session <id>`           |
| opencode | `~/.local/share/opencode/opencode.db` (SQLite)                      | `opencode --session <id>`     |
| cursor   | `~/.cursor/projects/*/agent-transcripts/*/*.jsonl`                  | `cursor-agent --resume <id>`  |
| grok     | `~/.grok/sessions/*/*/chat_history.jsonl` plus sibling `summary.json` | `grok --resume <id>`          |

With `--accept-all`, supported resume commands add the same permission-bypass
flags Ghostex uses: `codex --yolo`, `claude --dangerously-skip-permissions`,
`opencode --dangerously-skip-permissions`, `cursor-agent --yolo`, and
`grok --permission-mode bypassPermissions`. `pi` has no Accept All flag.

Each agent shows up in its own brand color, and each result shows a compact last-active time, so you can tell at a glance whether a result came from claude or codex and when that session was last active. Duplicate prompts collapse into one (keeping the most recent). Fuzzy search still leads ranking, but near-equivalent matches prefer newer sessions so a tiny score difference does not bury recent work.

opencode keeps its history in a SQLite database, so reading it needs the `sqlite3` CLI on your `PATH`. If it is missing, zehn skips opencode and says so instead of failing.

Codex session files can get large. zehn keeps a derived cache of extracted Codex
user prompts in `~/.ghostex/zehn/codex-sessions-v4`, invalidated by each source
file's size and modified time. Codex titles are read from `~/.codex/session_index.jsonl`
by session id so title changes can still appear when the transcript cache is warm.
The original session files remain the source of truth, and the cache can be
deleted at any time.

## How matching works

The search is not a plain substring filter. It is an fzf-style optimal alignment: a Smith-Waterman variant with affine gap penalties and extra credit for letters that land on word boundaries, camelCase humps, or in an unbroken run. In practice that means typing `auth` surfaces "add **auth** middleware" above some prompt where a, u, t, h happen to be scattered across the line.

"Optimal" is not a marketing word here. A test runs the matcher against a brute-force reference over thousands of random inputs and checks that the scores come out identical.

## Development

```sh
zig build test            # unit tests: matcher + all four parsers
zig build run -- --list
```

The matcher lives in `src/fuzzy.zig`, the per-agent parsers in `src/scan.zig`, and the terminal UI in `src/tui.zig`.

## Origin of the name

zehn (ذهن) means "the mind" in Persian and Arabic. It is short, it is easy to say (close to "zen"), and a tool whose whole job is remembering what you said to which agent might as well be named after memory.

## License

[PolyForm Noncommercial 1.0.0](LICENSE). Free to use, modify, and share for any
noncommercial purpose (personal projects, research, nonprofits, education).
Commercial use needs a separate license — open an issue or reach out.
