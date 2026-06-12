const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const scan = @import("scan.zig");
const tui = @import("tui.zig");
const favorites = @import("favorites.zig");
const fork = @import("fork.zig");
const build_options = @import("build_options");

const version = build_options.version;
const git_rev = build_options.git_rev;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &fw.interface;

    const home = init.environ_map.get("HOME") orelse {
        try w.writeAll("zehn: HOME not set\n");
        try w.flush();
        return;
    };

    const args = try init.minimal.args.toSlice(a);
    var print_project = false;
    var print_only = false;
    var list_only = false;
    // CDXC:AgentHistorySearch 2026-06-04-23:31:
    // Ghostex users can resume agent history from zehn while their app-wide Accept All policy is enabled. Keep standalone zehn opt-in with an explicit CLI flag so the search tool does not depend on gxserver state.
    var accept_all_resume = false;
    var agent_filter: ?scan.Agent = null;
    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try w.print("zehn {s} ({s})\n", .{ version, shortRev(git_rev) });
            try w.flush();
            return;
        } else if (std.mem.eql(u8, arg, "update")) {
            try selfUpdate(init, w);
            return;
        } else if (std.mem.eql(u8, arg, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, arg, "--project")) {
            print_project = true;
            print_only = true;
        } else if (std.mem.eql(u8, arg, "--agent")) {
            arg_i += 1;
            if (arg_i >= args.len) return usageError(w, "--agent needs one of: claude, codex, pi, opencode, cursor, grok");
            agent_filter = parseAgent(args[arg_i]) orelse return usageError(w, "unknown agent");
        } else if (std.mem.startsWith(u8, arg, "--agent=")) {
            agent_filter = parseAgent(arg[8..]) orelse return usageError(w, "unknown agent");
        } else if (parseAgentFlag(arg)) |agent| {
            agent_filter = agent;
        } else if (std.mem.eql(u8, arg, "--accept-all")) {
            accept_all_resume = true;
        } else if (std.mem.eql(u8, arg, "--no-accept-all")) {
            accept_all_resume = false;
        } else if (std.mem.eql(u8, arg, "--print")) {
            print_only = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try w.writeAll(
                \\zehn (ذهن, "the mind") — fuzzy finder & resumer for AI agent sessions
                \\
                \\Sources: claude (~/.claude), codex (~/.codex), pi (~/.pi),
                \\         opencode (~/.local/share/opencode/opencode.db, needs sqlite3),
                \\         cursor (~/.cursor/projects), grok (~/.grok/sessions)
                \\
                \\Usage:
                \\  zehn            find a prompt, then RESUME that session in its agent
                \\  zehn --print    just print the selected prompt text (no resume)
                \\  zehn --project  print agent<TAB>project<TAB>text (implies --print)
                \\  zehn --agent claude   show only one agent (claude/codex/pi/opencode/cursor/grok)
                \\  zehn --claude         shorthand for --agent claude
                \\  zehn --accept-all     resume with supported permission-bypass flags
                \\  zehn update     update zehn from the latest master build
                \\  zehn --list     dump all records
                \\
                \\Resume:  claude [--dangerously-skip-permissions] --resume <id>
                \\         codex [--yolo] resume <id>
                \\         pi --session <id>
                \\         opencode [--dangerously-skip-permissions] --session <id>
                \\         cursor-agent [--yolo] --resume <id>
                \\         grok [--permission-mode bypassPermissions] --resume <id>
                \\(run from the session's project directory)
                \\
                \\Keys: type to filter · ↑/↓ or ^p/^n move · Enter resume
                \\      mouse wheel moves · clicks do not select · ^d day grouping
                \\      PgUp/PgDn day · ^t agents · ^r projects
                \\      ^f favorite · ^e view · ^y copy · ^o fork
                \\      Esc/^c quit
                \\
                \\Favorites are stored in $XDG_CONFIG_HOME/zehn/favorites (or ~/.config/zehn).
                \\
            );
            try w.flush();
            return;
        }
    }

    if (list_only) {
        try listMode(a, io, home, w, agent_filter);
        return;
    }

    // CDXC:ZehnUpdateNotification 2026-06-07-08:12:
    // Zehn must never show an automatic update notification during normal search startup. Keep updates explicit through `zehn update` so launches stay quiet and offline unless the user asks to update.

    // CDXC:AgentHistorySearch 2026-06-07-14:59:
    // Interactive startup can spend visible time indexing previous agent prompts and metadata before the alternate-screen picker appears. Show a transient terminal status line while scanning so users are not left staring at a blank launch.
    const show_indexing_message = Io.File.stdout().isTty(io) catch false;
    if (show_indexing_message) try showIndexingMessage(w);
    var sc = scan.Scanner.init(a, io, home);
    sc.scanAll();
    if (show_indexing_message) try clearIndexingMessage(w);
    if (agent_filter) |agent| filterRecordsByAgent(&sc.records, agent);

    if (sc.sqlite_missing) {
        std.debug.print("zehn: opencode history found but 'sqlite3' is not installed — skipping opencode sessions.\n", .{});
    }

    if (sc.records.items.len == 0) {
        if (agent_filter) |agent| {
            try w.print("zehn: no {s} history found\n", .{agent.label()});
            try w.flush();
            return;
        }
        try w.writeAll("zehn: no history found\n");
        try w.flush();
        return;
    }

    // Favorites: a small persistent set so reused prompts can be starred and
    // floated to the top of results. Missing file just means an empty set.
    const xdg = init.environ_map.get("XDG_CONFIG_HOME");
    const fav_path = try favorites.pathFor(a, home, xdg);
    var fav = favorites.Set.init(a);
    favorites.load(&fav, io, a, fav_path);

    var t = tui.Tui.init(a, io, sc.records.items, &fav, fav_path);
    const picked = try t.run(w);

    if (picked) |action| {
        const rec = sc.records.items[action.idx];
        if (print_only) {
            if (print_project) {
                try w.print("{s}\t{s}\t", .{ rec.agent.label(), rec.project });
            }
            try writeSanitized(w, rec.text);
            try w.writeAll("\n");
            try w.flush();
            return;
        }
        switch (action.kind) {
            .resume_session => try resumeSession(init, io, w, rec, accept_all_resume),
            .copy => try copyPrompt(io, w, rec),
            .view => try viewPrompt(init, io, w, rec),
            .fork => try forkSession(init, io, w, rec, action.fork_agent),
        }
    }
}

fn showIndexingMessage(w: *Io.Writer) !void {
    try w.writeAll("\r\x1b[2KLoading: Indexing Previous User Prompts...");
    try w.flush();
}

fn clearIndexingMessage(w: *Io.Writer) !void {
    try w.writeAll("\r\x1b[2K");
    try w.flush();
}

fn usageError(w: *Io.Writer, msg: []const u8) !void {
    try w.print("zehn: {s}\n", .{msg});
    try w.writeAll("usage: zehn [--agent claude|codex|pi|opencode|cursor|grok] [--accept-all|--no-accept-all] [--print|--project|--list]\n");
    try w.flush();
}

fn parseAgent(name: []const u8) ?scan.Agent {
    for (scan.Agent.all()) |agent| {
        if (std.mem.eql(u8, name, agent.label())) return agent;
    }
    return null;
}

fn parseAgentFlag(arg: []const u8) ?scan.Agent {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    return parseAgent(arg[2..]);
}

fn filterRecordsByAgent(records: *std.ArrayList(scan.Record), agent: scan.Agent) void {
    var out: usize = 0;
    for (records.items) |rec| {
        if (rec.agent == agent) {
            records.items[out] = rec;
            out += 1;
        }
    }
    records.shrinkRetainingCapacity(out);
}

test "agent filter parsing accepts long and shorthand forms" {
    try std.testing.expectEqual(scan.Agent.claude, parseAgent("claude").?);
    try std.testing.expectEqual(scan.Agent.opencode, parseAgent("opencode").?);
    try std.testing.expectEqual(scan.Agent.cursor, parseAgent("cursor").?);
    try std.testing.expectEqual(scan.Agent.grok, parseAgent("grok").?);
    try std.testing.expectEqual(scan.Agent.codex, parseAgentFlag("--codex").?);
    try std.testing.expect(parseAgent("antigravity") == null);
}

test "agent filter keeps only requested records" {
    var records: std.ArrayList(scan.Record) = .empty;
    defer records.deinit(std.testing.allocator);
    try records.append(std.testing.allocator, .{ .agent = .claude, .text = "a", .project = "p", .session = "s", .ts = 1 });
    try records.append(std.testing.allocator, .{ .agent = .opencode, .text = "b", .project = "p", .session = "s", .ts = 2 });
    try records.append(std.testing.allocator, .{ .agent = .claude, .text = "c", .project = "p", .session = "s", .ts = 3 });

    filterRecordsByAgent(&records, .claude);

    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqual(scan.Agent.claude, records.items[0].agent);
    try std.testing.expectEqualStrings("a", records.items[0].text);
    try std.testing.expectEqualStrings("c", records.items[1].text);
}

fn shortRev(rev: []const u8) []const u8 {
    if (rev.len > 12) return rev[0..12];
    return rev;
}

fn remoteMasterCommand() []const u8 {
    return "curl -fsSL --max-time 2 https://api.github.com/repos/al3rez/zehn/commits/master 2>/dev/null | sed -n 's/.*\"sha\": *\"\\([0-9a-f]*\\)\".*/\\1/p' | head -n1";
}

/// Re-run the official installer. It builds from the latest master and replaces
/// the binary under $PREFIX/bin (default: ~/.local/bin), matching the install path.
fn selfUpdate(init: std.process.Init, w: *Io.Writer) !void {
    const cmd = try std.fmt.allocPrint(init.arena.allocator(),
        \\remote=$({s})
        \\if [ -n "$remote" ] && [ "$remote" = "{s}" ]; then
        \\  echo "zehn: already at latest master ({s})"
        \\  exit 0
        \\fi
        \\curl -fsSL https://raw.githubusercontent.com/al3rez/zehn/master/scripts/install.sh | sh
    , .{ remoteMasterCommand(), git_rev, shortRev(git_rev) });

    try w.writeAll("zehn: checking https://github.com/al3rez/zehn ...\n");
    try w.flush();
    var child = std.process.spawn(init.io, .{
        .argv = &.{ "sh", "-c", cmd },
        .environ_map = init.environ_map,
    }) catch |err| {
        try w.print("zehn: failed to start updater ({t})\n", .{err});
        try w.flush();
        return;
    };
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0) {
        try w.writeAll("zehn: update failed\n");
        try w.flush();
    }
}

fn viewPrompt(init: std.process.Init, io: Io, w: *Io.Writer, rec: scan.Record) !void {
    const editor = init.environ_map.get("EDITOR") orelse init.environ_map.get("VISUAL") orelse "nvim";
    const tmp = init.environ_map.get("TMPDIR") orelse "/tmp";
    const pid = switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
    const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/zehn-prompt-{d}.md", .{ tmp, pid });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rec.text }) catch |err| {
        try w.print("zehn: failed to write preview file ({t})\n", .{err});
        try w.flush();
        return;
    };
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var child = std.process.spawn(io, .{
        .argv = &.{ editor, path },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = init.environ_map,
    }) catch |err| {
        try w.print("zehn: failed to launch editor `{s}` ({t}); set $EDITOR if needed\n", .{ editor, err });
        try w.flush();
        return;
    };
    _ = try child.wait(io);
}

/// Copy the prompt text to the system clipboard, trying each platform tool in
/// turn. Text is fed on stdin so shell-special or multi-line prompts are safe.
fn copyPrompt(io: Io, w: *Io.Writer, rec: scan.Record) !void {
    for (fork.clipboardCandidates()) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        if (child.stdin) |f| {
            var wbuf: [4096]u8 = undefined;
            var fw = f.writer(io, &wbuf);
            fw.interface.writeAll(rec.text) catch {};
            fw.interface.flush() catch {};
            f.close(io);
            child.stdin = null;
        }
        const term = child.wait(io) catch continue;
        if (term == .exited and term.exited == 0) {
            try w.print("\x1b[90m→ copied {s} prompt to clipboard\x1b[0m\n", .{rec.agent.label()});
            try w.flush();
            return;
        }
    }
    try w.writeAll("zehn: no clipboard tool found (need pbcopy, wl-copy, xclip, or xsel)\n");
    try w.flush();
}

/// Fork the prompt into a fresh session in `agent` (possibly different from the
/// one it came from), starting in the recorded project dir when it still exists.
fn forkSession(init: std.process.Init, io: Io, w: *Io.Writer, rec: scan.Record, agent: scan.Agent) !void {
    var argv_buf = fork.freshSessionArgv(agent, rec.text);
    const argv: []const []const u8 = &argv_buf;

    var cwd: std.process.Child.Cwd = .inherit;
    var project_ok = false;
    if (rec.project.len > 0) {
        if (Io.Dir.cwd().openDir(io, rec.project, .{})) |d| {
            var dir = d;
            dir.close(io);
            cwd = .{ .path = rec.project };
            project_ok = true;
        } else |_| {}
    }

    try w.print("\x1b[90m→ forking prompt into a new {s} session", .{agent.label()});
    if (project_ok) try w.print(" in {s}", .{rec.project});
    try w.writeAll("\x1b[0m\n");
    try w.flush();

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = init.environ_map,
    }) catch |err| {
        try w.print("zehn: failed to launch {s} ({t})\n", .{ argv[0], err });
        try w.flush();
        return;
    };
    _ = try child.wait(io);
}

const ResumeArgv = struct {
    items: [5][]const u8 = undefined,
    len: usize = 0,

    fn slice(self: *const ResumeArgv) []const []const u8 {
        return self.items[0..self.len];
    }
};

fn resumeArgv(agent: scan.Agent, session: []const u8, accept_all: bool) ResumeArgv {
    if (accept_all) {
        return switch (agent) {
            .claude => .{ .items = .{ "claude", "--dangerously-skip-permissions", "--resume", session, undefined }, .len = 4 },
            .codex => .{ .items = .{ "codex", "--yolo", "resume", session, undefined }, .len = 4 },
            .pi => .{ .items = .{ "pi", "--session", session, undefined, undefined }, .len = 3 },
            .opencode => .{ .items = .{ "opencode", "--dangerously-skip-permissions", "--session", session, undefined }, .len = 4 },
            .cursor => .{ .items = .{ "cursor-agent", "--yolo", "--resume", session, undefined }, .len = 4 },
            .grok => .{ .items = .{ "grok", "--permission-mode", "bypassPermissions", "--resume", session }, .len = 5 },
        };
    }
    return switch (agent) {
        .claude => .{ .items = .{ "claude", "--resume", session, undefined, undefined }, .len = 3 },
        .codex => .{ .items = .{ "codex", "resume", session, undefined, undefined }, .len = 3 },
        .pi => .{ .items = .{ "pi", "--session", session, undefined, undefined }, .len = 3 },
        .opencode => .{ .items = .{ "opencode", "--session", session, undefined, undefined }, .len = 3 },
        .cursor => .{ .items = .{ "cursor-agent", "--resume", session, undefined, undefined }, .len = 3 },
        .grok => .{ .items = .{ "grok", "--resume", session, undefined, undefined }, .len = 3 },
    };
}

fn resumeSession(init: std.process.Init, io: Io, w: *Io.Writer, rec: scan.Record, accept_all: bool) !void {
    if (rec.session.len == 0) {
        try w.print("zehn: no session id recorded for this {s} entry\n", .{rec.agent.label()});
        try w.flush();
        return;
    }

    const argv_buf = resumeArgv(rec.agent, rec.session, accept_all);
    const argv = argv_buf.slice();

    // Resume from the recorded project dir, but fall back to the current dir
    // if it no longer exists (moved/deleted), rather than failing the spawn.
    var cwd: std.process.Child.Cwd = .inherit;
    var project_ok = false;
    if (rec.project.len > 0) {
        if (Io.Dir.cwd().openDir(io, rec.project, .{})) |d| {
            var dir = d;
            dir.close(io);
            cwd = .{ .path = rec.project };
            project_ok = true;
        } else |_| {}
    }

    try w.print("\x1b[90m→ resuming {s} session {s}", .{ rec.agent.label(), rec.session });
    if (project_ok) {
        try w.print(" in {s}", .{rec.project});
    } else if (rec.project.len > 0) {
        try w.print(" (project {s} missing — using current dir)", .{rec.project});
    }
    try w.writeAll("\x1b[0m\n");
    try w.flush();

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = init.environ_map,
    }) catch |err| {
        try w.print("zehn: failed to launch {s} ({t})\nRun manually:\n  cd {s} &&", .{
            argv[0],
            err,
            if (rec.project.len > 0) rec.project else ".",
        });
        for (argv) |part| {
            try w.print(" {s}", .{part});
        }
        try w.writeAll("\n");
        try w.flush();
        return;
    };
    _ = try child.wait(io);
}

test "resume argv optionally applies Ghostex Accept All flags" {
    {
        const argv_buf = resumeArgv(.codex, "codex-session", false);
        const argv = argv_buf.slice();
        try std.testing.expectEqual(@as(usize, 3), argv.len);
        try std.testing.expectEqualStrings("codex", argv[0]);
        try std.testing.expectEqualStrings("resume", argv[1]);
        try std.testing.expectEqualStrings("codex-session", argv[2]);
    }
    {
        const argv_buf = resumeArgv(.codex, "codex-session", true);
        const argv = argv_buf.slice();
        try std.testing.expectEqual(@as(usize, 4), argv.len);
        try std.testing.expectEqualStrings("codex", argv[0]);
        try std.testing.expectEqualStrings("--yolo", argv[1]);
        try std.testing.expectEqualStrings("resume", argv[2]);
        try std.testing.expectEqualStrings("codex-session", argv[3]);
    }
    {
        const argv_buf = resumeArgv(.claude, "claude-session", true);
        const argv = argv_buf.slice();
        try std.testing.expectEqualStrings("--dangerously-skip-permissions", argv[1]);
        try std.testing.expectEqualStrings("--resume", argv[2]);
    }
    {
        const argv_buf = resumeArgv(.opencode, "opencode-session", true);
        const argv = argv_buf.slice();
        try std.testing.expectEqualStrings("--dangerously-skip-permissions", argv[1]);
        try std.testing.expectEqualStrings("--session", argv[2]);
    }
    {
        const argv_buf = resumeArgv(.pi, "pi-session", true);
        const argv = argv_buf.slice();
        try std.testing.expectEqual(@as(usize, 3), argv.len);
        try std.testing.expectEqualStrings("pi", argv[0]);
        try std.testing.expectEqualStrings("--session", argv[1]);
        try std.testing.expectEqualStrings("pi-session", argv[2]);
    }
    {
        const argv_buf = resumeArgv(.cursor, "cursor-session", true);
        const argv = argv_buf.slice();
        try std.testing.expectEqual(@as(usize, 4), argv.len);
        try std.testing.expectEqualStrings("cursor-agent", argv[0]);
        try std.testing.expectEqualStrings("--yolo", argv[1]);
        try std.testing.expectEqualStrings("--resume", argv[2]);
        try std.testing.expectEqualStrings("cursor-session", argv[3]);
    }
    {
        const argv_buf = resumeArgv(.grok, "grok-session", true);
        const argv = argv_buf.slice();
        try std.testing.expectEqual(@as(usize, 5), argv.len);
        try std.testing.expectEqualStrings("grok", argv[0]);
        try std.testing.expectEqualStrings("--permission-mode", argv[1]);
        try std.testing.expectEqualStrings("bypassPermissions", argv[2]);
        try std.testing.expectEqualStrings("--resume", argv[3]);
        try std.testing.expectEqualStrings("grok-session", argv[4]);
    }
}

fn writeSanitized(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| {
        try w.writeByte(if (c == '\n' or c == '\t' or c == '\r') ' ' else c);
    }
}

fn listMode(a: std.mem.Allocator, io: Io, home: []const u8, w: *Io.Writer, agent_filter: ?scan.Agent) !void {
    var sc = scan.Scanner.init(a, io, home);
    sc.scanAll();
    if (agent_filter) |agent| filterRecordsByAgent(&sc.records, agent);
    for (sc.records.items) |rec| {
        try w.print("{s}\t{s}\t", .{ rec.agent.label(), rec.project });
        try writeSanitized(w, rec.text);
        try w.writeAll("\n");
    }
    try w.flush();
}
