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
    query_cursor: usize = 0,
    hits: std.ArrayList(Hit) = .empty,
    sel: usize = 0,
    top: usize = 0,
    preview_scroll: usize = 0,
    result_scroll: usize = 0,
    preview_focus: bool = false,
    wrap_preview: bool = true,
    fullscreen_preview: bool = false,
    /// Bit mask of selected agents in the interactive picker. 0 means no
    /// filter, so all agents are shown.
    agent_filter_mask: u4 = 0,
    rows: u16 = 24,
    cols: u16 = 80,
    orig: posix.termios = undefined,
    matcher: fuzzy.Matcher,
    fav: *favorites.Set,
    fav_path: []const u8,
    /// When set, the picker is in "fork into which agent?" mode and digit keys
    /// choose the target instead of typing into the query.
    forking: bool = false,
    /// When set, the preview area becomes an agent-filter picker.
    filtering_agent: bool = false,
    filter_sel: usize = 0,

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
            if (!self.agentAllowed(rec.agent)) continue;
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
        self.preview_scroll = 0;
        self.result_scroll = 0;
    }

    fn listHeight(self: *Tui) usize {
        // 1 prompt line + 1 separator + preview area.
        const preview_rows: usize = if (self.fullscreen_preview) self.rows -| 2 else 5;
        const reserved: usize = 1 + 1 + preview_rows;
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
        const scroll = if (selected) self.result_scroll else 0;
        var pi: usize = 0;
        var i: usize = @min(scroll, text.len);
        while (i < text.len and (text[i] & 0xC0) == 0x80) i += 1;
        if (i > 0) buf.appendSlice(self.a, "…") catch oom();
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
        self.writeQueryWithCursor(b);
        var cnt: [128]u8 = undefined;
        const cs = std.fmt.bufPrint(&cnt, "  \x1b[90m{d}/{d}  ·  ^t filter  ^f fav  ^y copy  ^o fork\x1b[0m\r\n", .{ self.hits.items.len, self.records.len }) catch "\r\n";
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
            if (selected) {
                b.appendSlice(self.a, agentColor(rec.agent)) catch oom();
                b.appendSlice(self.a, "▌\x1b[0m\x1b[7m ") catch oom();
            } else {
                b.appendSlice(self.a, "  ") catch oom();
            }
            // favorite marker (bold yellow star), or a blank to keep columns aligned
            if (hit.fav) {
                if (selected) {
                    b.appendSlice(self.a, "★") catch oom();
                } else {
                    b.appendSlice(self.a, "\x1b[1;33m★\x1b[0m") catch oom();
                }
                if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();
            } else {
                b.append(self.a, ' ') catch oom();
            }
            b.append(self.a, ' ') catch oom();
            // Agent colors look muddy under reverse-video selection in several
            // terminals, so selected rows keep one plain inverted style.
            if (!selected) b.appendSlice(self.a, agentColor(rec.agent)) catch oom();
            var tag: [16]u8 = undefined;
            const ts = std.fmt.bufPrint(&tag, "{s: <7}", .{rec.agent.label()}) catch rec.agent.label();
            b.appendSlice(self.a, ts) catch oom();
            if (!selected) b.appendSlice(self.a, "\x1b[0m") catch oom();
            if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();
            b.append(self.a, ' ') catch oom();
            self.writeHighlighted(b, rec.text, hit.m, text_max, selected);
            b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();
        }

        // separator
        b.appendSlice(self.a, "\x1b[90m") catch oom();
        var k: usize = 0;
        while (k < self.cols) : (k += 1) b.appendSlice(self.a, "─") catch oom();
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();

        // agent filter mode replaces the preview with a small picker
        if (self.filtering_agent) {
            self.writeAgentFilterPicker(b);
            try w.writeAll(b.items);
            try w.flush();
            return;
        }

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
            const preview_lines: usize = if (self.fullscreen_preview) self.rows -| 3 else 4;
            if (self.preview_focus) b.appendSlice(self.a, "\x1b[1;36mpreview\x1b[0m\r\n") catch oom();
            // preview lines, wrapped at display width when enabled, UTF-8 aware
            var i: usize = 0;
            var skipped: usize = 0;
            while (i < rec.text.len and skipped < self.preview_scroll) : (skipped += 1) {
                while (i < rec.text.len and rec.text[i] != '\n') i += 1;
                if (i < rec.text.len and rec.text[i] == '\n') i += 1;
            }
            var line_lines: usize = 0;
            while (i < rec.text.len and line_lines < preview_lines) {
                var used: usize = 0;
                const line_start = i;
                while (i < rec.text.len) {
                    if (rec.text[i] == '\n') break;
                    const d = uni.decode(rec.text[i..]);
                    const is_ctrl = d.cp < 0x20 or (d.cp >= 0x7f and d.cp < 0xa0);
                    const cw: usize = if (is_ctrl) 1 else uni.charWidth(d.cp);
                    if (used + cw > self.cols) {
                        if (!self.wrap_preview) break;
                        b.appendSlice(self.a, "\r\n") catch oom();
                        line_lines += 1;
                        used = 0;
                        if (line_lines >= preview_lines) break;
                    }
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
            self.writeStatusLine(b, rec);
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

                // While picking an agent filter, digits choose the filter and any
                // other key (esc included) cancels back to normal browsing.
                if (self.filtering_agent) {
                    if (c == 27) {
                        if (self.handleEscapeSequence(ibuf[i..n])) |consumed| {
                            i += consumed;
                            continue;
                        }
                        self.filtering_agent = false;
                        i += 1;
                        continue;
                    }
                    switch (c) {
                        13, 10, ' ' => self.toggleFilterSelection(),
                        '1' => {
                            self.filter_sel = 0;
                            self.toggleFilterSelection();
                        },
                        '2' => {
                            self.filter_sel = 1;
                            self.toggleFilterSelection();
                        },
                        '3' => {
                            self.filter_sel = 2;
                            self.toggleFilterSelection();
                        },
                        '4' => {
                            self.filter_sel = 3;
                            self.toggleFilterSelection();
                        },
                        14 => self.moveFilterSelection(1), // ctrl-n
                        16 => self.moveFilterSelection(-1), // ctrl-p
                        else => {},
                    }
                    i += 1;
                    continue;
                }

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
                    if (self.handleEscapeSequence(ibuf[i..n])) |consumed| {
                        i += consumed;
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
                    6 => { // ctrl-f
                        if (self.preview_focus) self.fullscreen_preview = !self.fullscreen_preview else self.toggleFavorite();
                    },
                    25 => { // ctrl-y: copy selected to clipboard
                        if (self.sel < self.hits.items.len)
                            return .{ .idx = self.hits.items[self.sel].idx, .kind = .copy };
                    },
                    9 => self.preview_focus = !self.preview_focus, // tab
                    15 => { // ctrl-o: fork into another agent
                        if (self.sel < self.hits.items.len) self.forking = true;
                    },
                    11 => self.killToEnd(), // ctrl-k
                    20 => self.openAgentFilterPicker(), // ctrl-t
                    21 => self.killToBeginning(), // ctrl-u
                    87, 119 => { // w/W
                        if (self.preview_focus) self.wrap_preview = !self.wrap_preview else self.insertQueryByte(c);
                    },
                    70, 102 => { // f/F
                        if (self.preview_focus) self.fullscreen_preview = !self.fullscreen_preview else self.insertQueryByte(c);
                    },
                    127, 8 => self.backspace(),
                    14 => self.moveDown(), // ctrl-n
                    16 => self.moveUp(), // ctrl-p
                    else => {
                        // accept printable ASCII and any UTF-8 continuation/lead
                        // bytes (>=128), but not DEL
                        if ((c >= 32 and c < 127) or c >= 128) {
                            self.insertQueryByte(c);
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

    fn handleEscapeSequence(self: *Tui, bytes: []const u8) ?usize {
        if (bytes.len < 3 or bytes[0] != 27 or bytes[1] != '[') return null;
        if (bytes[2] == '5' and bytes.len >= 4 and bytes[3] == '~') {
            self.scrollPreview(-1);
            return 4;
        }
        if (bytes[2] == '6' and bytes.len >= 4 and bytes[3] == '~') {
            self.scrollPreview(1);
            return 4;
        }
        if (bytes[2] == '3' and bytes.len >= 6 and bytes[3] == ';' and bytes[4] == '5' and bytes[5] == '~') {
            self.deleteWordForward(); // ctrl-delete
            return 6;
        }
        if (bytes.len >= 8 and bytes[2] == '1' and bytes[3] == '2' and bytes[4] == '7' and bytes[5] == ';' and bytes[6] == '5' and bytes[7] == 'u') {
            self.deleteWordBackward(); // ctrl-backspace (CSI u)
            return 8;
        }
        if (bytes.len >= 6 and bytes[2] == '8' and bytes[3] == ';' and bytes[4] == '5' and bytes[5] == 'u') {
            self.deleteWordBackward(); // ctrl-backspace (CSI u)
            return 6;
        }
        if (bytes.len >= 6 and bytes[2] == '1' and bytes[3] == ';' and bytes[4] == '5') {
            switch (bytes[5]) {
                'C' => { // ctrl-right
                    if (self.preview_focus) self.scrollResultToEnd() else self.moveWordRight();
                },
                'D' => { // ctrl-left
                    if (self.preview_focus) self.result_scroll = 0 else self.moveWordLeft();
                },
                else => {},
            }
            return 6;
        }
        switch (bytes[2]) {
            'A' => if (self.filtering_agent) self.moveFilterSelection(-1) else self.moveUp(),
            'B' => if (self.filtering_agent) self.moveFilterSelection(1) else self.moveDown(),
            'C' => if (self.preview_focus) self.scrollResult(8) else self.moveRight(),
            'D' => if (self.preview_focus) self.scrollResult(-8) else self.moveLeft(),
            else => {},
        }
        return 3;
    }

    fn writeQueryWithCursor(self: *Tui, b: *std.ArrayList(u8)) void {
        const q = self.query.items;
        const max: usize = if (self.cols > 44) self.cols - 44 else 20;
        var start: usize = 0;
        if (self.query_cursor > max / 2) start = self.query_cursor - max / 2;
        while (start < q.len and (q[start] & 0xC0) == 0x80) start += 1;
        var end: usize = @min(q.len, start + max);
        while (end < q.len and (q[end] & 0xC0) == 0x80) end -= 1;
        if (self.query_cursor >= end and end < q.len) {
            end = nextChar(q, self.query_cursor);
            start = if (end > max) end - max else 0;
            while (start < q.len and (q[start] & 0xC0) == 0x80) start += 1;
        }

        if (start > 0) b.appendSlice(self.a, "…") catch oom();
        b.appendSlice(self.a, q[start..self.query_cursor]) catch oom();
        b.appendSlice(self.a, "\x1b[7m") catch oom();
        if (self.query_cursor < q.len) {
            const d = uni.decode(q[self.query_cursor..]);
            b.appendSlice(self.a, q[self.query_cursor .. self.query_cursor + d.len]) catch oom();
        } else {
            b.append(self.a, ' ') catch oom();
        }
        b.appendSlice(self.a, "\x1b[0m") catch oom();
        if (self.query_cursor < q.len) {
            const d = uni.decode(q[self.query_cursor..]);
            b.appendSlice(self.a, q[self.query_cursor + d.len .. end]) catch oom();
        }
        if (end < q.len) b.appendSlice(self.a, "…") catch oom();
    }

    fn prevChar(q: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var p = pos - 1;
        while (p > 0 and (q[p] & 0xC0) == 0x80) p -= 1;
        return p;
    }

    fn nextChar(q: []const u8, pos: usize) usize {
        if (pos >= q.len) return q.len;
        return pos + uni.decode(q[pos..]).len;
    }

    fn writeStatusLine(self: *Tui, b: *std.ArrayList(u8), rec: scan.Record) void {
        const project = if (rec.project.len > 0) rec.project else "-";
        const pos = if (self.hits.items.len == 0) 0 else self.sel + 1;
        b.print(self.a, "\x1b[90m{s}  {d}/{d}", .{ project, pos, self.hits.items.len }) catch oom();
        self.writeAgentFilterStatus(b);
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();

        b.appendSlice(self.a, "\x1b[90m") catch oom();
        self.writeUsageStatus(b, rec.meta.usage);
        if (rec.meta.plan.len > 0) b.print(self.a, "({s}) ", .{rec.meta.plan}) catch oom();
        if (rec.meta.usage.rate_percent > 0) b.print(self.a, "{d:.1}%", .{rec.meta.usage.rate_percent}) catch oom();
        if (rec.meta.usage.context_window > 0) b.print(self.a, "/{d} ", .{rec.meta.usage.context_window}) catch oom();
        b.print(self.a, "({s})", .{if (rec.meta.provider.len > 0) rec.meta.provider else rec.agent.label()}) catch oom();
        if (rec.meta.model.len > 0) b.print(self.a, " {s}", .{rec.meta.model}) catch oom();
        if (rec.meta.thinking.len > 0) b.print(self.a, " • {s}", .{rec.meta.thinking}) catch oom();
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();
    }

    fn writeUsageStatus(self: *Tui, b: *std.ArrayList(u8), u: scan.Usage) void {
        if (u.input > 0) b.print(self.a, "↑{d} ", .{u.input}) catch oom();
        if (u.output > 0) b.print(self.a, "↓{d} ", .{u.output}) catch oom();
        if (u.cache_read > 0) b.print(self.a, "R{d} ", .{u.cache_read}) catch oom();
        if (u.cache_write > 0) b.print(self.a, "W{d} ", .{u.cache_write}) catch oom();
        if (u.cost > 0) b.print(self.a, "${d:.3} ", .{u.cost}) catch oom();
    }

    fn writeAgentFilterStatus(self: *Tui, b: *std.ArrayList(u8)) void {
        if (self.agent_filter_mask == 0) return;
        b.appendSlice(self.a, "  agents:") catch oom();
        var first = true;
        const agents = [_]scan.Agent{ .claude, .codex, .pi, .opencode };
        for (agents) |agent| {
            if ((self.agent_filter_mask & agentBit(agent)) == 0) continue;
            if (!first) b.append(self.a, ',') catch oom();
            b.appendSlice(self.a, agent.label()) catch oom();
            first = false;
        }
    }

    fn agentBit(agent: scan.Agent) u4 {
        return switch (agent) {
            .claude => 1 << 0,
            .codex => 1 << 1,
            .pi => 1 << 2,
            .opencode => 1 << 3,
        };
    }

    fn agentAllowed(self: *const Tui, agent: scan.Agent) bool {
        return self.agent_filter_mask == 0 or (self.agent_filter_mask & agentBit(agent)) != 0;
    }

    fn openAgentFilterPicker(self: *Tui) void {
        self.filtering_agent = true;
        self.filter_sel = 0;
    }

    fn moveFilterSelection(self: *Tui, delta: isize) void {
        if (delta < 0) {
            self.filter_sel = if (self.filter_sel == 0) 3 else self.filter_sel - 1;
        } else {
            self.filter_sel = (self.filter_sel + 1) % 4;
        }
    }

    fn toggleFilterSelection(self: *Tui) void {
        const agents = [_]scan.Agent{ .claude, .codex, .pi, .opencode };
        self.agent_filter_mask ^= agentBit(agents[self.filter_sel]);
        self.recompute();
    }

    fn writeAgentFilterPicker(self: *Tui, b: *std.ArrayList(u8)) void {
        b.appendSlice(self.a, "\r\n") catch oom();
        const agents = [_]scan.Agent{ .claude, .codex, .pi, .opencode };
        for (agents, 0..) |agent, idx| {
            b.appendSlice(self.a, if (idx == self.filter_sel) "→ " else "  ") catch oom();
            b.appendSlice(self.a, agentColor(agent)) catch oom();
            b.print(self.a, "{s}\x1b[0m", .{agent.label()}) catch oom();
            const selected = (self.agent_filter_mask & agentBit(agent)) != 0;
            b.print(self.a, "\x1b[90m{s}\x1b[0m\r\n", .{if (selected) " ✓" else ""}) catch oom();
        }
        b.appendSlice(self.a, "\r\n\x1b[90mSelect none to show all agents.\x1b[0m\r\n") catch oom();
        b.appendSlice(self.a, "\r\n\x1b[90m↑/↓ or ^p/^n move · Enter/Space toggle · 1-4 quick toggle · Esc close\x1b[0m\r\n") catch oom();
    }

    fn insertQueryByte(self: *Tui, c: u8) void {
        self.query.insert(self.a, self.query_cursor, c) catch oom();
        self.query_cursor += 1;
        self.recompute();
    }

    fn deleteRange(self: *Tui, start: usize, end: usize) void {
        if (end <= start) return;
        std.mem.copyForwards(u8, self.query.items[start..], self.query.items[end..]);
        self.query.shrinkRetainingCapacity(self.query.items.len - (end - start));
        self.query_cursor = start;
        self.recompute();
    }

    fn backspace(self: *Tui) void {
        if (self.query_cursor == 0) return;
        self.deleteRange(prevChar(self.query.items, self.query_cursor), self.query_cursor);
    }

    fn killToEnd(self: *Tui) void {
        self.deleteRange(self.query_cursor, self.query.items.len);
    }

    fn killToBeginning(self: *Tui) void {
        self.deleteRange(0, self.query_cursor);
    }

    fn moveLeft(self: *Tui) void {
        self.query_cursor = prevChar(self.query.items, self.query_cursor);
    }

    fn moveRight(self: *Tui) void {
        self.query_cursor = nextChar(self.query.items, self.query_cursor);
    }

    fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn moveWordLeft(self: *Tui) void {
        var p = self.query_cursor;
        while (p > 0 and !isWordByte(self.query.items[prevChar(self.query.items, p)])) p = prevChar(self.query.items, p);
        while (p > 0 and isWordByte(self.query.items[prevChar(self.query.items, p)])) p = prevChar(self.query.items, p);
        self.query_cursor = p;
    }

    fn moveWordRight(self: *Tui) void {
        var p = self.query_cursor;
        while (p < self.query.items.len and !isWordByte(self.query.items[p])) p = nextChar(self.query.items, p);
        while (p < self.query.items.len and isWordByte(self.query.items[p])) p = nextChar(self.query.items, p);
        self.query_cursor = p;
    }

    fn deleteWordForward(self: *Tui) void {
        const start = self.query_cursor;
        self.moveWordRight();
        self.deleteRange(start, self.query_cursor);
    }

    fn deleteWordBackward(self: *Tui) void {
        const end = self.query_cursor;
        self.moveWordLeft();
        self.deleteRange(self.query_cursor, end);
    }

    fn scrollResult(self: *Tui, delta: isize) void {
        if (delta < 0) {
            const d: usize = @intCast(-delta);
            self.result_scroll = if (d > self.result_scroll) 0 else self.result_scroll - d;
        } else {
            self.result_scroll += @intCast(delta);
        }
    }

    fn scrollResultToEnd(self: *Tui) void {
        if (self.sel < self.hits.items.len) {
            self.result_scroll = self.records[self.hits.items[self.sel].idx].text.len;
        }
    }

    fn scrollPreview(self: *Tui, delta: isize) void {
        if (delta < 0) {
            const d: usize = @intCast(-delta);
            self.preview_scroll = if (d > self.preview_scroll) 0 else self.preview_scroll - d;
        } else {
            self.preview_scroll += @intCast(delta);
        }
    }

    fn moveDown(self: *Tui) void {
        if (self.hits.items.len == 0) return;
        if (self.sel + 1 < self.hits.items.len) {
            self.sel += 1;
            self.preview_scroll = 0;
            self.result_scroll = 0;
        }
    }
    fn moveUp(self: *Tui) void {
        if (self.sel > 0) {
            self.sel -= 1;
            self.preview_scroll = 0;
            self.result_scroll = 0;
        }
    }
};

const testing = std.testing;

fn testTui() Tui {
    return Tui.init(testing.allocator, undefined, &.{}, undefined, "");
}

test "query render keeps typed search text visible with cursor" {
    var tui = testTui();
    defer tui.query.deinit(testing.allocator);
    tui.cols = 24;
    try tui.query.appendSlice(testing.allocator, "abcdef");
    tui.query_cursor = tui.query.items.len;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    tui.writeQueryWithCursor(&out);

    try testing.expect(std.mem.indexOf(u8, out.items, "abcdef") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[7m \x1b[0m") != null);
}

test "query supports readline-style character and line editing" {
    var tui = testTui();
    defer tui.query.deinit(testing.allocator);
    try tui.query.appendSlice(testing.allocator, "hello world");
    tui.query_cursor = tui.query.items.len;

    tui.moveLeft();
    tui.moveLeft();
    try testing.expectEqual(@as(usize, 9), tui.query_cursor);
    try tui.query.insert(testing.allocator, tui.query_cursor, '!');
    tui.query_cursor += 1;
    try testing.expectEqualStrings("hello wor!ld", tui.query.items);

    tui.backspace();
    try testing.expectEqualStrings("hello world", tui.query.items);
    try testing.expectEqual(@as(usize, 9), tui.query_cursor);

    tui.killToBeginning();
    try testing.expectEqualStrings("ld", tui.query.items);
    try testing.expectEqual(@as(usize, 0), tui.query_cursor);

    tui.killToEnd();
    try testing.expectEqualStrings("", tui.query.items);
}

test "query supports word movement and word deletion" {
    var tui = testTui();
    defer tui.query.deinit(testing.allocator);
    try tui.query.appendSlice(testing.allocator, "one two_three four");
    tui.query_cursor = 0;

    tui.moveWordRight();
    try testing.expectEqual(@as(usize, 3), tui.query_cursor);
    tui.deleteWordForward();
    try testing.expectEqualStrings("one four", tui.query.items);
    try testing.expectEqual(@as(usize, 3), tui.query_cursor);

    tui.query_cursor = tui.query.items.len;
    tui.deleteWordBackward();
    try testing.expectEqualStrings("one ", tui.query.items);
}

test "page up and down escape sequences scroll preview without typing tilde" {
    var tui = testTui();
    defer tui.query.deinit(testing.allocator);

    try testing.expectEqual(@as(?usize, 4), tui.handleEscapeSequence("\x1b[6~"));
    try testing.expectEqual(@as(usize, 1), tui.preview_scroll);
    try testing.expectEqualStrings("", tui.query.items);

    try testing.expectEqual(@as(?usize, 4), tui.handleEscapeSequence("\x1b[5~"));
    try testing.expectEqual(@as(usize, 0), tui.preview_scroll);
    try testing.expectEqualStrings("", tui.query.items);
}

test "focused preview uses arrows for result horizontal scroll" {
    var tui = testTui();
    defer tui.query.deinit(testing.allocator);
    tui.preview_focus = true;

    try testing.expectEqual(@as(?usize, 3), tui.handleEscapeSequence("\x1b[C"));
    try testing.expectEqual(@as(usize, 8), tui.result_scroll);
    try testing.expectEqual(@as(?usize, 3), tui.handleEscapeSequence("\x1b[D"));
    try testing.expectEqual(@as(usize, 0), tui.result_scroll);
}

test "horizontal result scroll exposes tail of skill-heavy prompts" {
    var tui = testTui();
    tui.result_scroll = 23;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    tui.writeHighlighted(&out, "/skill lots of boilerplate MY PROMPT", .{ .score = 0 }, 40, true);

    try testing.expect(std.mem.indexOf(u8, out.items, "MY PROMPT") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "/skill lots") == null);
}

test "golden: horizontally scrolled result row" {
    var tui = testTui();
    tui.result_scroll = 23;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    tui.writeHighlighted(&out, "/skill lots of boilerplate MY PROMPT", .{ .score = 0 }, 40, true);

    try testing.expectEqualStrings("…ate MY PROMPT", out.items);
}

test "preview focus keys cover scroll, jump, wrap and fullscreen state" {
    var tui = testTui();
    tui.preview_focus = true;
    tui.rows = 30;

    try testing.expectEqual(@as(?usize, 3), tui.handleEscapeSequence("\x1b[C"));
    try testing.expectEqual(@as(usize, 8), tui.result_scroll);
    try testing.expectEqual(@as(?usize, 6), tui.handleEscapeSequence("\x1b[1;5D"));
    try testing.expectEqual(@as(usize, 0), tui.result_scroll);

    tui.wrap_preview = true;
    tui.fullscreen_preview = false;
    try testing.expectEqual(@as(usize, 23), tui.listHeight());
    tui.wrap_preview = !tui.wrap_preview;
    tui.fullscreen_preview = !tui.fullscreen_preview;
    try testing.expect(!tui.wrap_preview);
    try testing.expect(tui.fullscreen_preview);
    try testing.expectEqual(@as(usize, 1), tui.listHeight());
}

test "selection changes reset preview and result scroll" {
    var fav = favorites.Set.init(testing.allocator);
    defer fav.deinit();
    const records = [_]scan.Record{
        .{ .agent = .claude, .project = "p", .session = "s1", .text = "first", .ts = 1 },
        .{ .agent = .claude, .project = "p", .session = "s2", .text = "second", .ts = 2 },
    };
    var tui = Tui.init(testing.allocator, undefined, &records, &fav, "");
    defer tui.hits.deinit(testing.allocator);
    tui.recompute();
    tui.preview_scroll = 3;
    tui.result_scroll = 9;

    tui.moveDown();

    try testing.expectEqual(@as(usize, 0), tui.preview_scroll);
    try testing.expectEqual(@as(usize, 0), tui.result_scroll);
}

test "interactive agent filter picker filters hits" {
    var fav = favorites.Set.init(testing.allocator);
    defer fav.deinit();
    const records = [_]scan.Record{
        .{ .agent = .claude, .project = "p", .session = "s1", .text = "same", .ts = 1 },
        .{ .agent = .opencode, .project = "p", .session = "s2", .text = "same", .ts = 2 },
    };
    var tui = Tui.init(testing.allocator, undefined, &records, &fav, "");
    defer tui.hits.deinit(testing.allocator);
    tui.recompute();
    try testing.expectEqual(@as(usize, 2), tui.hits.items.len);
    try testing.expectEqual(@as(u4, 0), tui.agent_filter_mask);

    tui.openAgentFilterPicker();
    try testing.expectEqual(@as(usize, 0), tui.filter_sel);
    tui.toggleFilterSelection();
    try testing.expectEqual(@as(u4, 1), tui.agent_filter_mask);
    try testing.expectEqual(@as(usize, 1), tui.hits.items.len);
    try testing.expectEqual(scan.Agent.claude, records[tui.hits.items[0].idx].agent);

    tui.filter_sel = 3;
    tui.toggleFilterSelection();
    try testing.expectEqual(@as(u4, 9), tui.agent_filter_mask);
    try testing.expectEqual(@as(usize, 2), tui.hits.items.len);

    tui.filter_sel = 0;
    tui.toggleFilterSelection();
    try testing.expectEqual(@as(u4, 8), tui.agent_filter_mask);
    try testing.expectEqual(@as(usize, 1), tui.hits.items.len);
    try testing.expectEqual(scan.Agent.opencode, records[tui.hits.items[0].idx].agent);

    tui.filter_sel = 3;
    tui.toggleFilterSelection();
    try testing.expectEqual(@as(u4, 0), tui.agent_filter_mask);
    try testing.expectEqual(@as(usize, 2), tui.hits.items.len);
}

test "agent filter picker arrow keys move selection" {
    var tui = testTui();
    tui.openAgentFilterPicker();

    try testing.expectEqual(@as(?usize, 3), tui.handleEscapeSequence("\x1b[B"));
    try testing.expectEqual(@as(usize, 1), tui.filter_sel);
    try testing.expectEqual(@as(?usize, 3), tui.handleEscapeSequence("\x1b[A"));
    try testing.expectEqual(@as(usize, 0), tui.filter_sel);
}
