const std = @import("std");
const Io = std.Io;
const scan = @import("scan.zig");
const tui = @import("tui.zig");

const version = "0.1.0";

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
                \\Keys: type to filter · ↑/↓ or ^p/^n move · Enter select · Esc quit
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

    var t = tui.Tui.init(a, io, sc.records.items);
    const picked = try t.run(w);

    if (picked) |idx| {
        const rec = sc.records.items[idx];
        if (print_only) {
            if (print_project) {
                try w.print("{s}\t{s}\t", .{ rec.agent.label(), rec.project });
            }
            try writeSanitized(w, rec.text);
            try w.writeAll("\n");
            try w.flush();
            return;
        }
        try resumeSession(init, io, w, rec);
    }
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
            argv[0], err,
            if (rec.project.len > 0) rec.project else ".",
            argv[0],            argv[1],            argv[2],
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
