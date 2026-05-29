const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const scan = @import("scan.zig");
const fuzzy = @import("fuzzy.zig");
const uni = @import("unicode.zig");
const favorites = @import("favorites.zig");

/// What the user chose to do with the selected record. `resume` is the default
/// (Enter); `copy` puts the prompt on the clipboard; `fork` starts a fresh
/// session with the prompt in `fork_agent` (possibly a different agent).
pub const Action = struct {
    idx: usize,
    kind: Kind,
    fork_agent: scan.Agent = .claude,

    pub const Kind = enum { resume_session, copy, fork };
};

// TIOCGWINSZ is platform-specific: the Linux value differs from the BSD/Darwin
// one, and issuing the wrong request (or going through std.os.linux on a
// non-Linux target) returns garbage instead of failing — which is how the
// terminal size came back as 0xAAAA on macOS and scrolled the whole UI away.
const TIOCGWINSZ: c_int = switch (builtin.os.tag) {
    .linux => 0x5413,
    else => 0x40087468, // macOS/BSD
};

/// Allocation failure while building a frame is unrecoverable; crash loudly
/// rather than silently rendering a corrupt screen. (Terminal-cleanup paths
/// keep best-effort `catch {}` since they run during teardown/signals.)
fn oom() noreturn {
    @panic("out of memory");
}

// Saved terminal state for restoration from a signal handler (which cannot
// take arguments). Set while the TUI owns the terminal.
var g_orig: posix.termios = undefined;
var g_active: bool = false;

fn restoreTerminal() void {
    if (!g_active) return;
    g_active = false;
    const seq = "\x1b[?25h\x1b[?1049l"; // show cursor, leave alt-screen
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.write(1, seq.ptr, seq.len),
        else => _ = std.c.write(1, seq.ptr, seq.len),
    }
    posix.tcsetattr(0, .FLUSH, g_orig) catch {};
}

fn onSignal(sig: posix.SIG) callconv(.c) void {
    restoreTerminal();
    // restore default disposition and re-raise so exit status reflects signal
    const act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &act, null);
    _ = posix.raise(sig) catch {};
}

fn installSignalHandlers() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]posix.SIG{ .INT, .TERM, .HUP, .QUIT }) |s| {
        posix.sigaction(s, &act, null);
    }
}

const Hit = struct {
    idx: u32,
    score: i32,
    fav: bool,
    m: fuzzy.Match,
};

// Official brand colors as 24-bit truecolor.
fn agentColor(a: scan.Agent) []const u8 {
    return switch (a) {
        .claude => "\x1b[38;2;218;119;86m", // #DA7756 Anthropic terra cotta
        .codex => "\x1b[38;2;16;163;127m", // #10A37F OpenAI green
        .opencode => "\x1b[38;2;207;206;205m", // #CFCECD opencode logo gray
        .pi => "\x1b[38;2;136;192;208m", // #88C0D0 pi Nord frost
    };
}

pub const Tui = struct {
    a: std.mem.Allocator,
    io: Io,
    records: []const scan.Record,
    query: std.ArrayList(u8) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    sel: usize = 0,
    top: usize = 0,
    rows: u16 = 24,
    cols: u16 = 80,
    orig: posix.termios = undefined,
    matcher: fuzzy.Matcher,
    fav: *favorites.Set,
    fav_path: []const u8,
    /// When set, the picker is in "fork into which agent?" mode and digit keys
    /// choose the target instead of typing into the query.
    forking: bool = false,

    pub fn init(a: std.mem.Allocator, io: Io, records: []const scan.Record, fav: *favorites.Set, fav_path: []const u8) Tui {
        return .{
            .a = a,
            .io = io,
            .records = records,
            .matcher = fuzzy.Matcher.init(a),
            .fav = fav,
            .fav_path = fav_path,
        };
    }

    fn winsize(self: *Tui) void {
        var ws: posix.winsize = undefined;
        const ok = switch (builtin.os.tag) {
            .linux => std.os.linux.ioctl(0, @intCast(TIOCGWINSZ), @intFromPtr(&ws)) == 0,
            else => std.c.ioctl(0, TIOCGWINSZ, @intFromPtr(&ws)) == 0,
        };
        // Reject implausible sizes: a bad ioctl can leave `ws` uninitialised
        // (we've seen 0xAAAA come back on macOS), and a multi-thousand-row
        // "terminal" makes render() emit a giant blank frame that scrolls all
        // real output off-screen — looking like the app printed nothing.
        if (ok and ws.row > 0 and ws.col > 0 and ws.row <= 4096 and ws.col <= 4096) {
            self.rows = ws.row;
            self.cols = ws.col;
        }
    }

    fn enterRaw(self: *Tui) !void {
        self.orig = try posix.tcgetattr(0);
        g_orig = self.orig;
        var t = self.orig;
        t.lflag.ICANON = false;
        t.lflag.ECHO = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.iflag.IXON = false;
        t.iflag.ICRNL = false;
        try posix.tcsetattr(0, .FLUSH, t);
        g_active = true;
    }

    fn leaveRaw(self: *Tui) void {
        g_active = false;
        posix.tcsetattr(0, .FLUSH, self.orig) catch {};
    }

    fn recompute(self: *Tui) void {
        self.hits.clearRetainingCapacity();
        const q = self.query.items;
        for (self.records, 0..) |rec, i| {
            if (self.matcher.match(q, rec.text)) |m| {
                const is_fav = self.fav.contains(favorites.key(rec.agent.label(), rec.text));
                self.hits.append(self.a, .{ .idx = @intCast(i), .score = m.score, .fav = is_fav, .m = m }) catch oom();
            }
        }
        std.mem.sort(Hit, self.hits.items, self.records, struct {
            fn lt(recs: []const scan.Record, x: Hit, y: Hit) bool {
                // Favorites form a strict tier above the rest (see favorites.rank).
                const rx = favorites.rank(x.score, x.fav);
                const ry = favorites.rank(y.score, y.fav);
                if (rx != ry) return rx > ry;
                const tx = recs[x.idx].ts;
                const ty = recs[y.idx].ts;
                if (tx != ty) return tx > ty; // newer first
                return x.idx < y.idx;
            }
        }.lt);
        self.sel = 0;
        self.top = 0;
    }

    fn listHeight(self: *Tui) usize {
        // 1 prompt line + 1 separator + preview(5)
        const reserved: usize = 1 + 1 + 5;
        if (self.rows <= reserved + 1) return 1;
        return self.rows - reserved;
    }

    fn clampScroll(self: *Tui) void {
        const h = self.listHeight();
        if (self.sel < self.top) self.top = self.sel;
        if (self.sel >= self.top + h) self.top = self.sel + 1 - h;
    }

    // Render `text` on a single line: UTF-8 aware, truncated to `max` display
    // columns, with matched bytes highlighted. Highlight positions are byte
    // offsets (matches are byte-wise); a codepoint is highlighted if its first
    // byte is a match position.
    fn writeHighlighted(self: *Tui, buf: *std.ArrayList(u8), text: []const u8, m: fuzzy.Match, max: usize, selected: bool) void {
        var pi: usize = 0;
        var i: usize = 0;
        var used: usize = 0;
        while (i < text.len) {
            const d = uni.decode(text[i..]);
            // sanitize control chars (incl. newlines/tabs) to a space
            const is_ctrl = d.cp < 0x20 or (d.cp >= 0x7f and d.cp < 0xa0);
            const cw: usize = if (is_ctrl) 1 else uni.charWidth(d.cp);
            if (used + cw > max) {
                buf.appendSlice(self.a, "…") catch oom();
                return;
            }
            // advance highlight cursor past any positions before i
            while (pi < m.pos_len and m.positions[pi] < i) pi += 1;
            const hl = pi < m.pos_len and m.positions[pi] == i;
            if (hl) {
                pi += 1;
                buf.appendSlice(self.a, "\x1b[1;33m") catch oom(); // bold yellow
            }
            if (is_ctrl) {
                buf.append(self.a, ' ') catch oom();
            } else {
                buf.appendSlice(self.a, text[i .. i + d.len]) catch oom();
            }
            if (hl) {
                buf.appendSlice(self.a, "\x1b[0m") catch oom();
                if (selected) buf.appendSlice(self.a, "\x1b[7m") catch oom();
            }
            used += cw;
            i += d.len;
        }
    }

    fn render(self: *Tui, w: *Io.Writer) !void {
        self.winsize(); // pick up live terminal resizes
        self.clampScroll();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.a);
        const b = &buf;

        b.appendSlice(self.a, "\x1b[2J\x1b[H") catch oom(); // clear + home

        // prompt line
        b.appendSlice(self.a, "\x1b[1;36m❯ \x1b[0m") catch oom();
        b.appendSlice(self.a, self.query.items) catch oom();
        var cnt: [128]u8 = undefined;
        const cs = std.fmt.bufPrint(&cnt, "  \x1b[90m{d}/{d}  ·  ^f fav  ^y copy  ^o fork\x1b[0m\r\n", .{ self.hits.items.len, self.records.len }) catch "\r\n";
        b.appendSlice(self.a, cs) catch oom();

        const h = self.listHeight();
        const text_max: usize = if (self.cols > 16) self.cols - 16 else 20;
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const hi = self.top + row;
            if (hi >= self.hits.items.len) {
                b.appendSlice(self.a, "\r\n") catch oom();
                continue;
            }
            const hit = self.hits.items[hi];
            const rec = self.records[hit.idx];
            const selected = hi == self.sel;
            if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();
            b.appendSlice(self.a, if (selected) "▌ " else "  ") catch oom();
            // favorite marker (bold yellow star), or a blank to keep columns aligned
            if (hit.fav) {
                b.appendSlice(self.a, "\x1b[1;33m★\x1b[0m") catch oom();
                if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();
            } else {
                b.append(self.a, ' ') catch oom();
            }
            b.append(self.a, ' ') catch oom();
            // agent tag
            b.appendSlice(self.a, agentColor(rec.agent)) catch oom();
            var tag: [16]u8 = undefined;
            const ts = std.fmt.bufPrint(&tag, "{s: <7}", .{rec.agent.label()}) catch rec.agent.label();
            b.appendSlice(self.a, ts) catch oom();
            b.appendSlice(self.a, "\x1b[0m") catch oom();
            if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();
            b.append(self.a, ' ') catch oom();
            self.writeHighlighted(b, rec.text, hit.m, text_max, selected);
            b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();
        }

        // separator
        b.appendSlice(self.a, "\x1b[90m") catch oom();
        var k: usize = 0;
        while (k < self.cols) : (k += 1) b.append(self.a, '-') catch oom();
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();

        // fork mode replaces the preview with an agent picker
        if (self.forking) {
            b.appendSlice(self.a, "\x1b[1;36mfork prompt into:\x1b[0m  ") catch oom();
            b.appendSlice(self.a, "\x1b[1m1\x1b[0m claude  \x1b[1m2\x1b[0m codex  \x1b[1m3\x1b[0m pi  \x1b[1m4\x1b[0m opencode") catch oom();
            b.appendSlice(self.a, "  \x1b[90m(esc cancels)\x1b[0m\r\n") catch oom();
            try w.writeAll(b.items);
            try w.flush();
            return;
        }

        // preview of selected
        if (self.sel < self.hits.items.len) {
            const rec = self.records[self.hits.items[self.sel].idx];
            var pv: [256]u8 = undefined;
            const head = std.fmt.bufPrint(&pv, "\x1b[90magent:\x1b[0m {s}  \x1b[90mproject:\x1b[0m {s}\r\n", .{ rec.agent.label(), if (rec.project.len > 0) rec.project else "-" }) catch "";
            b.appendSlice(self.a, head) catch oom();
            // up to 4 lines, wrapped at display width, UTF-8 aware
            var i: usize = 0;
            var line_lines: usize = 0;
            while (i < rec.text.len and line_lines < 4) {
                var used: usize = 0;
                const line_start = i;
                while (i < rec.text.len) {
                    if (rec.text[i] == '\n') break;
                    const d = uni.decode(rec.text[i..]);
                    const is_ctrl = d.cp < 0x20 or (d.cp >= 0x7f and d.cp < 0xa0);
                    const cw: usize = if (is_ctrl) 1 else uni.charWidth(d.cp);
                    if (used + cw > self.cols) break;
                    if (is_ctrl) b.append(self.a, ' ') catch oom() else b.appendSlice(self.a, rec.text[i .. i + d.len]) catch oom();
                    used += cw;
                    i += d.len;
                }
                b.appendSlice(self.a, "\r\n") catch oom();
                // if we stopped on a newline, skip it
                if (i < rec.text.len and rec.text[i] == '\n') i += 1;
                line_lines += 1;
                if (i == line_start and used == 0) i += 1; // guarantee progress
            }
        }

        try w.writeAll(b.items);
        try w.flush();
    }

    /// Returns the chosen Action, or null if cancelled.
    pub fn run(self: *Tui, w: *Io.Writer) !?Action {
        self.winsize();
        installSignalHandlers();
        try self.enterRaw();
        defer self.leaveRaw();
        try w.writeAll("\x1b[?1049h\x1b[?25l"); // alt screen, hide cursor
        try w.flush();
        defer {
            w.writeAll("\x1b[?25h\x1b[?1049l") catch {}; // show cursor, leave alt screen
            w.flush() catch {};
        }

        self.recompute();

        var ibuf: [256]u8 = undefined;
        while (true) {
            try self.render(w);
            const n = posix.read(0, &ibuf) catch break;
            if (n == 0) break;
            var i: usize = 0;
            while (i < n) {
                const c = ibuf[i];

                // While picking a fork target, digits choose the agent and any
                // other key (esc included) cancels back to normal browsing.
                if (self.forking) {
                    self.forking = false;
                    if (self.sel < self.hits.items.len) {
                        const agent: ?scan.Agent = switch (c) {
                            '1' => .claude,
                            '2' => .codex,
                            '3' => .pi,
                            '4' => .opencode,
                            else => null,
                        };
                        if (agent) |ag| return .{
                            .idx = self.hits.items[self.sel].idx,
                            .kind = .fork,
                            .fork_agent = ag,
                        };
                    }
                    i += 1;
                    continue;
                }

                if (c == 27) {
                    // escape sequence (arrows) or bare ESC
                    if (i + 2 < n and ibuf[i + 1] == '[') {
                        switch (ibuf[i + 2]) {
                            'A' => self.moveUp(),
                            'B' => self.moveDown(),
                            else => {},
                        }
                        i += 3;
                        continue;
                    }
                    return null; // bare ESC quits
                }
                switch (c) {
                    3 => return null, // ctrl-c
                    13, 10 => {
                        if (self.sel < self.hits.items.len)
                            return .{ .idx = self.hits.items[self.sel].idx, .kind = .resume_session };
                        return null;
                    },
                    6 => self.toggleFavorite(), // ctrl-f
                    25 => { // ctrl-y: copy selected to clipboard
                        if (self.sel < self.hits.items.len)
                            return .{ .idx = self.hits.items[self.sel].idx, .kind = .copy };
                    },
                    15 => { // ctrl-o: fork into another agent
                        if (self.sel < self.hits.items.len) self.forking = true;
                    },
                    127, 8 => {
                        if (self.query.items.len > 0) {
                            // pop a full UTF-8 codepoint
                            _ = self.query.pop();
                            while (self.query.items.len > 0 and
                                (self.query.items[self.query.items.len - 1] & 0xC0) == 0x80)
                            {
                                _ = self.query.pop();
                            }
                            self.recompute();
                        }
                    },
                    14 => self.moveDown(), // ctrl-n
                    16 => self.moveUp(), // ctrl-p
                    else => {
                        // accept printable ASCII and any UTF-8 continuation/lead
                        // bytes (>=128), but not DEL
                        if ((c >= 32 and c < 127) or c >= 128) {
                            self.query.append(self.a, c) catch oom();
                            self.recompute();
                        }
                    },
                }
                i += 1;
            }
        }
        return null;
    }

    /// Toggle the favorite flag of the selected prompt, persist, and re-rank.
    /// Selection follows the same record across the re-sort so the cursor does
    /// not jump after starring/unstarring.
    fn toggleFavorite(self: *Tui) void {
        if (self.sel >= self.hits.items.len) return;
        const rec_idx = self.hits.items[self.sel].idx;
        const rec = self.records[rec_idx];
        _ = self.fav.toggle(favorites.key(rec.agent.label(), rec.text)) catch return;
        favorites.save(self.fav, self.io, self.a, self.fav_path);
        self.recompute();
        for (self.hits.items, 0..) |hh, j| {
            if (hh.idx == rec_idx) {
                self.sel = j;
                break;
            }
        }
    }

    fn moveDown(self: *Tui) void {
        if (self.hits.items.len == 0) return;
        if (self.sel + 1 < self.hits.items.len) self.sel += 1;
    }
    fn moveUp(self: *Tui) void {
        if (self.sel > 0) self.sel -= 1;
    }
};
