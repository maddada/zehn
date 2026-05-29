const std = @import("std");
const Io = std.Io;
const scan = @import("scan.zig");
const tui = @import("tui.zig");
const favorites = @import("favorites.zig");
const fork = @import("fork.zig");

const version = "0.2.1";

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
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try w.print("zehn {s}\n", .{version});
            try w.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--list")) {
            try listMode(a, io, home, w);
            return;
        } else if (std.mem.eql(u8, arg, "--project")) {
            print_project = true;
            print_only = true;
        } else if (std.mem.eql(u8, arg, "--print")) {
            print_only = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try w.writeAll(
                \\zehn (ذهن, "the mind") — fuzzy finder & resumer for AI agent sessions
                \\
                \\Sources: claude (~/.claude), codex (~/.codex), pi (~/.pi),
                \\         opencode (~/.local/share/opencode/opencode.db, needs sqlite3)
                \\
                \\Usage:
                \\  zehn            find a prompt, then RESUME that session in its agent
                \\  zehn --print    just print the selected prompt text (no resume)
                \\  zehn --project  print agent<TAB>project<TAB>text (implies --print)
                \\  zehn --list     dump all records
                \\
                \\Resume:  claude --resume <id> | codex resume <id>
                \\         pi --session <id> | opencode --session <id>
                \\(run from the session's project directory)
                \\
                \\Keys: type to filter · ↑/↓ or ^p/^n move · Enter resume
                \\      ^f favorite (sorts to top) · ^y copy prompt · ^o fork into another agent
                \\      Esc/^c quit
                \\
                \\Favorites are stored in $XDG_CONFIG_HOME/zehn/favorites (or ~/.config/zehn).
                \\
            );
            try w.flush();
            return;
        }
    }

    var sc = scan.Scanner.init(a, io, home);
    sc.scanAll();

    if (sc.sqlite_missing) {
        std.debug.print("zehn: opencode history found but 'sqlite3' is not installed — skipping opencode sessions.\n", .{});
    }

    if (sc.records.items.len == 0) {
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
            .resume_session => try resumeSession(init, io, w, rec),
            .copy => try copyPrompt(io, w, rec),
            .fork => try forkSession(init, io, w, rec, action.fork_agent),
        }
    }
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

fn resumeSession(init: std.process.Init, io: Io, w: *Io.Writer, rec: scan.Record) !void {
    if (rec.session.len == 0) {
        try w.print("zehn: no session id recorded for this {s} entry\n", .{rec.agent.label()});
        try w.flush();
        return;
    }

    // Build the agent-specific resume argv.
    const argv: []const []const u8 = switch (rec.agent) {
        .claude => &.{ "claude", "--resume", rec.session },
        .codex => &.{ "codex", "resume", rec.session },
        .pi => &.{ "pi", "--session", rec.session },
        .opencode => &.{ "opencode", "--session", rec.session },
    };

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
        try w.print("zehn: failed to launch {s} ({t})\nRun manually:\n  cd {s} && {s} {s} {s}\n", .{
            argv[0],                                       err,
            if (rec.project.len > 0) rec.project else ".", argv[0],
            argv[1],                                       argv[2],
        });
        try w.flush();
        return;
    };
    _ = try child.wait(io);
}

fn writeSanitized(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| {
        try w.writeByte(if (c == '\n' or c == '\t' or c == '\r') ' ' else c);
    }
}

fn listMode(a: std.mem.Allocator, io: Io, home: []const u8, w: *Io.Writer) !void {
    var sc = scan.Scanner.init(a, io, home);
    sc.scanAll();
    for (sc.records.items) |rec| {
        try w.print("{s}\t{s}\t", .{ rec.agent.label(), rec.project });
        try writeSanitized(w, rec.text);
        try w.writeAll("\n");
    }
    try w.flush();
}
