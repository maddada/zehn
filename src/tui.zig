const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const scan = @import("scan.zig");
const fuzzy = @import("fuzzy.zig");
const uni = @import("unicode.zig");
const favorites = @import("favorites.zig");

/// What the user chose to do with the selected record. `resume` is the default
/// (Enter); `copy` puts the prompt on the clipboard; `view` opens it in
/// $EDITOR; `fork` starts a fresh session with the prompt in `fork_agent`
/// (possibly a different agent).
pub const Action = struct {
    idx: usize,
    kind: Kind,
    fork_agent: scan.Agent = .claude,

    pub const Kind = enum { resume_session, copy, view, fork };
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

const ViewRow = union(enum) {
    day: i64,
    hit: usize,
};

const seconds_per_day: i64 = 86_400;
const unknown_day_key: i64 = std.math.minInt(i64);

// Official brand colors as 24-bit truecolor.
fn agentColor(a: scan.Agent) []const u8 {
    return switch (a) {
        .claude => "\x1b[38;2;218;119;86m", // #DA7756 Anthropic terra cotta
        .codex => "\x1b[38;2;16;163;127m", // #10A37F OpenAI green
        .opencode => "\x1b[38;2;207;206;205m", // #CFCECD opencode logo gray
        .pi => "\x1b[38;2;136;192;208m", // #88C0D0 pi Nord frost
        .cursor => "\x1b[38;2;74;144;226m", // Cursor blue
        .grok => "\x1b[38;2;180;160;255m", // xAI/Grok purple accent
    };
}

pub const Tui = struct {
    a: std.mem.Allocator,
    io: Io,
    records: []const scan.Record,
    query: std.ArrayList(u8) = .empty,
    query_cursor: usize = 0,
    hits: std.ArrayList(Hit) = .empty,
    view_rows: std.ArrayList(ViewRow) = .empty,
    sel: usize = 0,
    top: usize = 0,
    preview_scroll: usize = 0,
    result_scroll: usize = 0,
    preview_focus: bool = false,
    wrap_preview: bool = true,
    fullscreen_preview: bool = false,
    // CDXC:AgentHistorySearch 2026-06-07-08:27:
    // Search results should default to day-grouped browsing so users can see when sessions were last active. Ctrl-D toggles the grouping, and plain left/right jump to the first session in adjacent day groups while grouped.
    group_by_day: bool = true,
    /// Bit mask of selected agents in the interactive picker. 0 means no
    /// filter, so all agents are shown.
    agent_filter_mask: u8 = 0,
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
    filtering_project: bool = false,
    filter_sel: usize = 0,
    project_filter: ?[]const u8 = null,
    project_sel: usize = 0,
    project_query: std.ArrayList(u8) = .empty,

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
            if (self.project_filter) |p| if (!std.mem.eql(u8, rec.project, p)) continue;
            if (self.matcher.match(q, rec.text)) |m| {
                const is_fav = self.fav.contains(favorites.key(rec.agent.label(), rec.text));
                self.hits.append(self.a, .{ .idx = @intCast(i), .score = m.score, .fav = is_fav, .m = m }) catch oom();
            }
        }
        std.mem.sort(Hit, self.hits.items, SortContext{ .records = self.records, .query_empty = q.len == 0, .group_by_day = self.group_by_day }, hitLess);
        self.rebuildViewRows();
        self.sel = 0;
        self.top = 0;
        self.preview_scroll = 0;
        self.result_scroll = 0;
    }

    const SortContext = struct {
        records: []const scan.Record,
        query_empty: bool,
        group_by_day: bool,
    };

    fn hitLess(ctx: SortContext, x: Hit, y: Hit) bool {
        const tx = ctx.records[x.idx].ts;
        const ty = ctx.records[y.idx].ts;
        if (ctx.group_by_day) {
            const dx = dayKey(tx);
            const dy = dayKey(ty);
            if (dx != dy) return dx > dy;
        }
        if (x.fav != y.fav) return x.fav;
        if (ctx.query_empty) {
            if (tx != ty) return tx > ty;
            if (x.score != y.score) return x.score > y.score;
            return x.idx < y.idx;
        }
        const bx = scoreBucket(x.score);
        const by = scoreBucket(y.score);
        if (bx != by) return bx > by;
        if (tx != ty) return tx > ty;
        if (x.score != y.score) return x.score > y.score;
        return x.idx < y.idx;
    }

    fn scoreBucket(score: i32) i32 {
        return @divFloor(score, 32);
    }

    fn dayKey(ts: i64) i64 {
        if (ts <= 0) return unknown_day_key;
        return @divFloor(ts, seconds_per_day);
    }

    fn rebuildViewRows(self: *Tui) void {
        self.view_rows.clearRetainingCapacity();
        if (!self.group_by_day) {
            for (self.hits.items, 0..) |_, i| self.view_rows.append(self.a, .{ .hit = i }) catch oom();
            return;
        }
        var last_day: ?i64 = null;
        for (self.hits.items, 0..) |hit, i| {
            const d = dayKey(self.records[hit.idx].ts);
            if (last_day == null or last_day.? != d) {
                self.view_rows.append(self.a, .{ .day = d }) catch oom();
                last_day = d;
            }
            self.view_rows.append(self.a, .{ .hit = i }) catch oom();
        }
    }

    fn bottomPaneHeight(self: *const Tui) usize {
        if (self.filtering_agent or self.filtering_project) {
            // Pi-style selectors keep up to ~10 visible items plus search/hints.
            // Give the picker more room and shrink the results list instead of
            // overflowing the terminal when the window is short.
            return @min(@as(usize, 13), self.rows -| 3);
        }
        return if (self.fullscreen_preview) self.rows -| 2 else 7;
    }

    fn listHeight(self: *Tui) usize {
        // 1 prompt line + 1 separator + bottom pane.
        const reserved: usize = 1 + 1 + self.bottomPaneHeight();
        if (self.rows <= reserved + 1) return 1;
        return self.rows - reserved;
    }

    fn bottomRowsAfterList(self: *const Tui, list_height: usize) usize {
        return self.rows -| (1 + list_height + 1);
    }

    fn selectedViewRow(self: *const Tui) usize {
        for (self.view_rows.items, 0..) |row, i| {
            switch (row) {
                .hit => |hit_idx| if (hit_idx == self.sel) return i,
                .day => {},
            }
        }
        return 0;
    }

    fn viewRowHeight(row: ViewRow) usize {
        return switch (row) {
            .day => 1,
            .hit => 2,
        };
    }

    fn visualOffsetForViewRow(self: *const Tui, target: usize) usize {
        var offset: usize = 0;
        var i: usize = 0;
        while (i < target and i < self.view_rows.items.len) : (i += 1) {
            offset += viewRowHeight(self.view_rows.items[i]);
        }
        return offset;
    }

    fn clampScroll(self: *Tui) void {
        const h = self.listHeight();
        if (self.view_rows.items.len == 0) {
            self.top = 0;
            return;
        }
        const selected_row = self.selectedViewRow();
        if (self.top >= self.view_rows.items.len) self.top = self.view_rows.items.len - 1;
        const selected_offset = self.visualOffsetForViewRow(selected_row);
        const selected_height = viewRowHeight(self.view_rows.items[selected_row]);
        const top_offset = self.visualOffsetForViewRow(self.top);
        if (selected_offset < top_offset) {
            self.top = selected_row;
            return;
        }
        if (selected_offset + selected_height <= top_offset + h) return;
        self.top = selected_row;
        var visible = selected_height;
        while (self.top > 0) {
            const prev_height = viewRowHeight(self.view_rows.items[self.top - 1]);
            if (visible + prev_height > h) break;
            self.top -= 1;
            visible += prev_height;
        }
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

    fn writeDayHeaderRow(self: *Tui, b: *std.ArrayList(u8), day: i64, now: i64) void {
        var label_buf: [32]u8 = undefined;
        const label = formatDayHeader(&label_buf, day, now);
        b.print(self.a, "  \x1b[1;90m{s}\x1b[0m\r\n", .{label}) catch oom();
    }

    fn writeResultRow(self: *Tui, b: *std.ArrayList(u8), hit_idx: usize, text_max: usize, now: i64, max_lines: usize) usize {
        if (max_lines == 0) return 0;
        const hit = self.hits.items[hit_idx];
        const rec = self.records[hit.idx];
        const selected = hit_idx == self.sel;
        if (selected) {
            b.appendSlice(self.a, agentColor(rec.agent)) catch oom();
            b.appendSlice(self.a, "▌\x1b[0m\x1b[7m ") catch oom();
        } else {
            b.appendSlice(self.a, "  ") catch oom();
        }
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

        if (!selected) b.appendSlice(self.a, agentColor(rec.agent)) catch oom();
        var agent_buf: [16]u8 = undefined;
        const agent = std.fmt.bufPrint(&agent_buf, "{s: <7}", .{rec.agent.label()}) catch rec.agent.label();
        b.appendSlice(self.a, agent) catch oom();
        if (!selected) b.appendSlice(self.a, "\x1b[0m") catch oom();
        if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();

        var compact_buf: [16]u8 = undefined;
        var time_buf: [16]u8 = undefined;
        const compact = formatLastActiveCompact(&compact_buf, rec.ts, now);
        const time_label = std.fmt.bufPrint(&time_buf, "{s: >7}", .{compact}) catch compact;
        b.append(self.a, ' ') catch oom();
        if (!selected) b.appendSlice(self.a, "\x1b[90m") catch oom();
        b.appendSlice(self.a, time_label) catch oom();
        if (!selected) b.appendSlice(self.a, "\x1b[0m") catch oom();
        if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();

        b.append(self.a, ' ') catch oom();
        if (selected) b.appendSlice(self.a, "\x1b[1m") catch oom();
        self.appendPlainTruncated(b, sessionTitle(rec), text_max);
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();
        if (max_lines == 1) return 1;

        if (selected) {
            b.appendSlice(self.a, "\x1b[7m    ") catch oom();
        } else {
            b.appendSlice(self.a, "    ") catch oom();
        }
        b.appendSlice(self.a, "\x1b[90m") catch oom();
        b.appendSlice(self.a, "prompt ") catch oom();
        b.appendSlice(self.a, "\x1b[0m") catch oom();
        if (selected) b.appendSlice(self.a, "\x1b[7m") catch oom();
        self.writeHighlighted(b, rec.text, hit.m, text_max, selected);
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();
        return 2;
    }

    fn sessionTitle(rec: scan.Record) []const u8 {
        if (rec.title.len > 0) return rec.title;
        if (rec.session.len > 0) return rec.session;
        return "Untitled session";
    }

    fn formatLastActiveCompact(buf: *[16]u8, ts: i64, now: i64) []const u8 {
        if (ts <= 0) return "unknown";
        var delta = now - ts;
        if (delta < 0) delta = 0;
        if (delta < 60) return "now";
        if (delta < 3_600) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(delta, 60)}) catch "now";
        if (delta < seconds_per_day) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(delta, 3_600)}) catch "now";
        if (delta < 7 * seconds_per_day) return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(delta, seconds_per_day)}) catch "now";
        const date = civilFromDayKey(dayKey(ts));
        return std.fmt.bufPrint(buf, "{s} {d}", .{ monthName(date.month), date.day }) catch "unknown";
    }

    fn nowSeconds(self: *Tui) i64 {
        return @intCast(@divTrunc(Io.Clock.real.now(self.io).nanoseconds, 1_000_000_000));
    }

    fn formatDayHeader(buf: *[32]u8, day: i64, now: i64) []const u8 {
        if (day == unknown_day_key) return "Unknown day";
        const today = dayKey(now);
        if (day == today) return "Today";
        if (day == today - 1) return "Yesterday";
        if (day > today - 7 and day < today) return std.fmt.bufPrint(buf, "{d} days ago", .{today - day}) catch "Recent";
        const date = civilFromDayKey(day);
        const now_date = civilFromDayKey(today);
        if (date.year == now_date.year) return std.fmt.bufPrint(buf, "{s} {d}", .{ monthName(date.month), date.day }) catch "Older";
        return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ monthName(date.month), date.day, date.year }) catch "Older";
    }

    const CivilDate = struct {
        year: i64,
        month: u8,
        day: u8,
    };

    fn civilFromDayKey(day: i64) CivilDate {
        const z = day + 719_468;
        const era = @divFloor(z, 146_097);
        const doe = z - era * 146_097;
        const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
        var y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9);
        if (m <= 2) y += 1;
        return .{ .year = y, .month = @intCast(m), .day = @intCast(d) };
    }

    fn monthName(month: u8) []const u8 {
        return switch (month) {
            1 => "Jan",
            2 => "Feb",
            3 => "Mar",
            4 => "Apr",
            5 => "May",
            6 => "Jun",
            7 => "Jul",
            8 => "Aug",
            9 => "Sep",
            10 => "Oct",
            11 => "Nov",
            12 => "Dec",
            else => "???",
        };
    }

    // Write the assembled frame, dropping a single trailing newline first. The
    // frame is sized to fill the terminal exactly, so a final CRLF would push
    // the cursor one row below the bottom and scroll the whole alt screen up —
    // sweeping the sticky `❯` prompt off the top. Leaving the cursor parked on
    // the last row keeps row 1 (the prompt) pinned, since render() always
    // redraws from a clear+home.
    fn flushFrame(_: *Tui, w: *Io.Writer, b: *std.ArrayList(u8)) !void {
        var items = b.items;
        if (std.mem.endsWith(u8, items, "\r\n")) items = items[0 .. items.len - 2];
        try w.writeAll(items);
        try w.flush();
    }

    fn render(self: *Tui, w: *Io.Writer) !void {
        self.winsize(); // pick up live terminal resizes
        self.clampScroll();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.a);
        const b = &buf;

        b.appendSlice(self.a, "\x1b[2J\x1b[H") catch oom(); // clear + home

        self.writePromptLine(b);

        const h = self.listHeight();
        const now = self.nowSeconds();
        const text_max: usize = if (self.cols > 24) self.cols - 24 else 20;
        var row: usize = 0;
        var row_idx = self.top;
        while (row < h) {
            if (row_idx >= self.view_rows.items.len) {
                b.appendSlice(self.a, "\r\n") catch oom();
                row += 1;
                continue;
            }
            switch (self.view_rows.items[row_idx]) {
                .day => |day| {
                    self.writeDayHeaderRow(b, day, now);
                    row += 1;
                },
                .hit => |hit_idx| {
                    row += self.writeResultRow(b, hit_idx, text_max, now, h - row);
                },
            }
            row_idx += 1;
        }

        b.appendSlice(self.a, "\x1b[90m") catch oom();
        var k: usize = 0;
        const sep_cols = @max(@as(usize, 1), @as(usize, self.cols) -| 1);
        while (k < sep_cols) : (k += 1) b.appendSlice(self.a, "─") catch oom();
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();

        if (self.filtering_project) {
            self.writeProjectFilterPicker(b, self.bottomRowsAfterList(h));
            try self.flushFrame(w, b);
            return;
        }

        // agent filter mode replaces the preview with a small picker
        if (self.filtering_agent) {
            self.writeAgentFilterPicker(b, self.bottomRowsAfterList(h));
            try self.flushFrame(w, b);
            return;
        }

        // fork mode replaces the preview with an agent picker
        if (self.forking) {
            b.appendSlice(self.a, "\x1b[1;36mfork prompt into:\x1b[0m  ") catch oom();
            b.appendSlice(self.a, "\x1b[1m1\x1b[0m claude  \x1b[1m2\x1b[0m codex  \x1b[1m3\x1b[0m pi  \x1b[1m4\x1b[0m opencode  \x1b[1m5\x1b[0m cursor  \x1b[1m6\x1b[0m grok") catch oom();
            b.appendSlice(self.a, "  \x1b[90m(esc cancels)\x1b[0m\r\n") catch oom();
            try self.flushFrame(w, b);
            return;
        }

        if (self.sel < self.hits.items.len) {
            const rec = self.records[self.hits.items[self.sel].idx];
            const bottom_rows = self.bottomRowsAfterList(h);
            self.writeProjectLine(b, rec);
            const has_preview_title = self.preview_focus and bottom_rows > 4;
            const fixed_rows: usize = 3 + @as(usize, @intFromBool(has_preview_title)); // project line + blank + optional title + metadata line
            const preview_lines: usize = if (bottom_rows > fixed_rows) bottom_rows - fixed_rows else 1;
            const preview_cols = @max(@as(usize, 1), @as(usize, self.cols) -| 1);
            if (has_preview_title) b.appendSlice(self.a, "\x1b[1;36mpreview\x1b[0m\r\n") catch oom();
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
                var filled = false; // a wrap already consumed the last budgeted row
                while (i < rec.text.len) {
                    if (rec.text[i] == '\n') break;
                    const d = uni.decode(rec.text[i..]);
                    const is_ctrl = d.cp < 0x20 or (d.cp >= 0x7f and d.cp < 0xa0);
                    const cw: usize = if (is_ctrl) 1 else uni.charWidth(d.cp);
                    if (used + cw > preview_cols) {
                        if (!self.wrap_preview) break;
                        b.appendSlice(self.a, "\r\n") catch oom();
                        line_lines += 1;
                        used = 0;
                        if (line_lines >= preview_lines) {
                            filled = true;
                            break;
                        }
                    }
                    if (is_ctrl) b.append(self.a, ' ') catch oom() else b.appendSlice(self.a, rec.text[i .. i + d.len]) catch oom();
                    used += cw;
                    i += d.len;
                }
                // The wrap above already emitted this row's newline and counted it.
                // Emitting the line terminator again would make the frame one line
                // taller than the terminal, scrolling the prompt and first row off
                // the top of the alt screen.
                if (filled) break;
                b.appendSlice(self.a, "\r\n") catch oom();
                if (i < rec.text.len and rec.text[i] == '\n') i += 1;
                line_lines += 1;
                if (i == line_start and used == 0) i += 1; // guarantee progress
            }
            self.writeMetadataLine(b, rec);
        }

        try self.flushFrame(w, b);
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

                if (self.filtering_project) {
                    if (c == 27) {
                        if (self.handleEscapeSequence(ibuf[i..n])) |consumed| {
                            i += consumed;
                            continue;
                        }
                        self.filtering_project = false;
                        i += 1;
                        continue;
                    }
                    switch (c) {
                        13, 10 => {
                            self.applyProjectFilterSelection();
                            self.filtering_project = false;
                        },
                        ' ' => self.toggleProjectFilterSelection(),
                        127, 8 => self.backspaceProjectQuery(),
                        14 => self.moveProjectSelection(1),
                        16 => self.moveProjectSelection(-1),
                        else => {
                            if ((c >= 32 and c < 127) or c >= 128) self.insertProjectQueryByte(c);
                        },
                    }
                    i += 1;
                    continue;
                }

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
                        '5' => {
                            self.filter_sel = 4;
                            self.toggleFilterSelection();
                        },
                        '6' => {
                            self.filter_sel = 5;
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
                            '5' => .cursor,
                            '6' => .grok,
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
                    4 => self.toggleDayGrouping(), // ctrl-d
                    13, 10 => {
                        if (self.sel < self.hits.items.len)
                            return .{ .idx = self.hits.items[self.sel].idx, .kind = .resume_session };
                        return null;
                    },
                    6 => { // ctrl-f
                        if (self.preview_focus) self.fullscreen_preview = !self.fullscreen_preview else self.toggleFavorite();
                    },
                    5 => { // ctrl-e: open selected prompt in $EDITOR
                        if (self.sel < self.hits.items.len)
                            return .{ .idx = self.hits.items[self.sel].idx, .kind = .view };
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
                    18 => self.openProjectFilterPicker(), // ctrl-r
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

    fn toggleDayGrouping(self: *Tui) void {
        const rec_idx: ?u32 = if (self.sel < self.hits.items.len) self.hits.items[self.sel].idx else null;
        self.group_by_day = !self.group_by_day;
        self.recompute();
        if (rec_idx) |idx| self.selectRecord(idx);
    }

    fn selectRecord(self: *Tui, rec_idx: u32) void {
        for (self.hits.items, 0..) |hit, i| {
            if (hit.idx == rec_idx) {
                self.selectHit(i);
                return;
            }
        }
    }

    fn selectHit(self: *Tui, hit_idx: usize) void {
        if (hit_idx >= self.hits.items.len) return;
        self.sel = hit_idx;
        self.preview_scroll = 0;
        self.result_scroll = 0;
    }

    fn jumpDay(self: *Tui, delta: isize) void {
        if (self.hits.items.len == 0 or self.sel >= self.hits.items.len) return;
        const current_day = dayKey(self.records[self.hits.items[self.sel].idx].ts);
        if (delta > 0) {
            var i = self.sel + 1;
            while (i < self.hits.items.len) : (i += 1) {
                if (dayKey(self.records[self.hits.items[i].idx].ts) != current_day) {
                    self.selectHit(i);
                    return;
                }
            }
            return;
        }
        var i = self.sel;
        while (i > 0) {
            i -= 1;
            const candidate_day = dayKey(self.records[self.hits.items[i].idx].ts);
            if (candidate_day == current_day) continue;
            while (i > 0 and dayKey(self.records[self.hits.items[i - 1].idx].ts) == candidate_day) i -= 1;
            self.selectHit(i);
            return;
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
            'A' => if (self.filtering_project) self.moveProjectSelection(-1) else if (self.filtering_agent) self.moveFilterSelection(-1) else self.moveUp(),
            'B' => if (self.filtering_project) self.moveProjectSelection(1) else if (self.filtering_agent) self.moveFilterSelection(1) else self.moveDown(),
            'C' => if (self.preview_focus) self.scrollResult(8) else if (self.group_by_day) self.jumpDay(1) else self.moveRight(),
            'D' => if (self.preview_focus) self.scrollResult(-8) else if (self.group_by_day) self.jumpDay(-1) else self.moveLeft(),
            else => {},
        }
        return 3;
    }

    fn writePromptLine(self: *Tui, b: *std.ArrayList(u8)) void {
        const prefix_cols: usize = 2;
        const status_cols: usize = if (self.cols >= 96)
            2 + countDigits(self.hits.items.len) + 1 + countDigits(self.records.len) + 72
        else if (self.cols >= 64)
            2 + countDigits(self.hits.items.len) + 1 + countDigits(self.records.len) + 25
        else
            2 + countDigits(self.hits.items.len) + 1 + countDigits(self.records.len);
        // Keep one column spare before CRLF. Many terminals auto-wrap as soon as
        // the cursor reaches the last column, which adds a physical line and can
        // scroll the sticky prompt off the top of the alt screen.
        const line_cols = @max(@as(usize, 1), @as(usize, self.cols) -| 1);
        const query_max = @max(@as(usize, 1), line_cols -| (prefix_cols + status_cols));

        b.appendSlice(self.a, "\x1b[1;36m❯ \x1b[0m") catch oom();
        self.writeQueryWithCursor(b, query_max);
        if (self.cols >= 96) {
            b.print(self.a, "  \x1b[90m{d}/{d}  ·  ^d days  ^t agents  ^r projects  ^f fav  ^e view  ^y copy  ^o fork\x1b[0m", .{ self.hits.items.len, self.records.len }) catch oom();
        } else if (self.cols >= 64) {
            b.print(self.a, "  \x1b[90m{d}/{d}  ·  ^d ^t ^r ^f ^e ^y ^o\x1b[0m", .{ self.hits.items.len, self.records.len }) catch oom();
        } else {
            b.print(self.a, "  \x1b[90m{d}/{d}\x1b[0m", .{ self.hits.items.len, self.records.len }) catch oom();
        }
        b.appendSlice(self.a, "\r\n") catch oom();
    }

    fn countDigits(n: usize) usize {
        var x = n;
        var digits: usize = 1;
        while (x >= 10) : (digits += 1) x /= 10;
        return digits;
    }

    fn writeQueryWithCursor(self: *Tui, b: *std.ArrayList(u8), max: usize) void {
        const q = self.query.items;
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

    fn writeProjectLine(self: *Tui, b: *std.ArrayList(u8), rec: scan.Record) void {
        const max_cols = @max(@as(usize, 1), @as(usize, self.cols) -| 1);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.a);
        const project = if (rec.project.len > 0) rec.project else "-";
        line.appendSlice(self.a, project) catch oom();
        if (self.gitBranch(rec.project)) |branch| line.print(self.a, " ({s})", .{branch}) catch oom();
        const pos = if (self.hits.items.len == 0) 0 else self.sel + 1;
        line.print(self.a, "  {d}/{d}", .{ pos, self.hits.items.len }) catch oom();
        self.appendAgentFilterStatusPlain(&line);

        b.appendSlice(self.a, "\x1b[90m") catch oom();
        self.appendPlainTruncated(b, line.items, max_cols);
        b.appendSlice(self.a, "\x1b[0m\r\n\r\n") catch oom();
    }

    fn writeMetadataLine(self: *Tui, b: *std.ArrayList(u8), rec: scan.Record) void {
        b.appendSlice(self.a, "\x1b[90m") catch oom();
        var active_buf: [48]u8 = undefined;
        b.print(self.a, "{s} ", .{formatLastActiveFull(&active_buf, rec.ts)}) catch oom();
        self.writeUsageStatus(b, rec.meta.usage);
        if (rec.meta.plan.len > 0) b.print(self.a, "({s}) ", .{rec.meta.plan}) catch oom();
        if (rec.meta.usage.rate_percent > 0) b.print(self.a, "{d:.1}%", .{rec.meta.usage.rate_percent}) catch oom();
        if (rec.meta.usage.context_window > 0) b.print(self.a, "/{d} ", .{rec.meta.usage.context_window}) catch oom();
        if (rec.meta.provider.len > 0) b.print(self.a, "({s})", .{rec.meta.provider}) catch oom();
        if (rec.meta.model.len > 0) {
            if (rec.meta.provider.len > 0) b.append(self.a, ' ') catch oom();
            b.print(self.a, "{s}", .{rec.meta.model}) catch oom();
        }
        if (rec.meta.thinking.len > 0) b.print(self.a, " • {s}", .{rec.meta.thinking}) catch oom();
        b.appendSlice(self.a, "\x1b[0m\r\n") catch oom();
    }

    fn formatLastActiveFull(buf: *[48]u8, ts: i64) []const u8 {
        if (ts <= 0) return "last active unknown";
        const day = dayKey(ts);
        const date = civilFromDayKey(day);
        const seconds = @mod(ts, seconds_per_day);
        const hour = @divTrunc(seconds, 3_600);
        const minute = @divTrunc(@mod(seconds, 3_600), 60);
        return std.fmt.bufPrint(buf, "last active {s} {d} {d:0>2}:{d:0>2} UTC", .{ monthName(date.month), date.day, hour, minute }) catch "last active known";
    }

    fn gitBranch(self: *Tui, project: []const u8) ?[]const u8 {
        if (project.len == 0) return null;
        const head_path = std.fmt.allocPrint(self.a, "{s}/.git/HEAD", .{project}) catch return null;
        const data = Io.Dir.cwd().readFileAlloc(self.io, head_path, self.a, .limited(4096)) catch return null;
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        const prefix = "ref: refs/heads/";
        if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
        return trimmed[prefix.len..];
    }

    fn writeUsageStatus(self: *Tui, b: *std.ArrayList(u8), u: scan.Usage) void {
        if (u.input > 0) b.print(self.a, "↑{d} ", .{u.input}) catch oom();
        if (u.output > 0) b.print(self.a, "↓{d} ", .{u.output}) catch oom();
        if (u.cache_read > 0) b.print(self.a, "R{d} ", .{u.cache_read}) catch oom();
        if (u.cache_write > 0) b.print(self.a, "W{d} ", .{u.cache_write}) catch oom();
        if (u.cost > 0) b.print(self.a, "${d:.3} ", .{u.cost}) catch oom();
    }

    fn appendPlainTruncated(self: *Tui, b: *std.ArrayList(u8), text: []const u8, max_cols: usize) void {
        var used: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const d = uni.decode(text[i..]);
            const is_ctrl = d.cp < 0x20 or (d.cp >= 0x7f and d.cp < 0xa0);
            const cw: usize = if (is_ctrl) 1 else uni.charWidth(d.cp);
            if (used + cw > max_cols) {
                if (max_cols > 0) b.appendSlice(self.a, "…") catch oom();
                return;
            }
            if (is_ctrl) b.append(self.a, ' ') catch oom() else b.appendSlice(self.a, text[i .. i + d.len]) catch oom();
            used += cw;
            i += d.len;
        }
    }

    fn appendAgentFilterStatusPlain(self: *Tui, b: *std.ArrayList(u8)) void {
        if (self.agent_filter_mask == 0) return;
        b.appendSlice(self.a, "  agents:") catch oom();
        var first = true;
        for (scan.Agent.all()) |agent| {
            if ((self.agent_filter_mask & agentBit(agent)) == 0) continue;
            if (!first) b.append(self.a, ',') catch oom();
            b.appendSlice(self.a, agent.label()) catch oom();
            first = false;
        }
    }

    fn writeAgentFilterStatus(self: *Tui, b: *std.ArrayList(u8)) void {
        self.appendAgentFilterStatusPlain(b);
    }

    fn agentBit(agent: scan.Agent) u8 {
        return switch (agent) {
            .claude => 1 << 0,
            .codex => 1 << 1,
            .pi => 1 << 2,
            .opencode => 1 << 3,
            .cursor => 1 << 4,
            .grok => 1 << 5,
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
            self.filter_sel = if (self.filter_sel == 0) scan.Agent.all().len - 1 else self.filter_sel - 1;
        } else {
            self.filter_sel = (self.filter_sel + 1) % scan.Agent.all().len;
        }
    }

    fn toggleFilterSelection(self: *Tui) void {
        self.agent_filter_mask ^= agentBit(scan.Agent.all()[self.filter_sel]);
        self.recompute();
    }

    fn writeAgentFilterPicker(self: *Tui, b: *std.ArrayList(u8), max_rows: usize) void {
        b.appendSlice(self.a, "\r\n") catch oom();
        const agents = scan.Agent.all();
        const rows = @min(max_rows, agents.len);
        for (agents[0..rows], 0..) |agent, idx| {
            const focused = idx == self.filter_sel;
            const selected = (self.agent_filter_mask & agentBit(agent)) != 0;
            if (focused) {
                b.appendSlice(self.a, "\x1b[1;36m→ ") catch oom();
                b.print(self.a, "{s}\x1b[0m", .{agent.label()}) catch oom();
            } else {
                b.print(self.a, "  {s}", .{agent.label()}) catch oom();
            }
            if (selected) b.appendSlice(self.a, " \x1b[1;32m✓\x1b[0m") catch oom();
            b.appendSlice(self.a, "\r\n") catch oom();
        }
        b.appendSlice(self.a, "\r\n\x1b[90mSelect none to show all agents.\x1b[0m\r\n") catch oom();
        b.appendSlice(self.a, "\r\n\x1b[90m↑/↓ or ^p/^n move · Enter/Space toggle · 1-4 quick toggle · Esc close\x1b[0m\r\n") catch oom();
    }

    fn projectIsFirst(self: *Tui, idx: usize) bool {
        const p = self.records[idx].project;
        for (self.records[0..idx]) |rec| if (std.mem.eql(u8, rec.project, p)) return false;
        return true;
    }

    fn projectMatches(self: *Tui, project: []const u8) bool {
        const q = self.project_query.items;
        if (q.len == 0) return true;
        const base = std.fs.path.basename(project);
        return std.ascii.indexOfIgnoreCase(base, q) != null or std.ascii.indexOfIgnoreCase(project, q) != null;
    }

    fn projectCount(self: *Tui) usize {
        var count: usize = 0;
        for (self.records, 0..) |rec, i| {
            if (rec.project.len > 0 and self.projectIsFirst(i) and self.projectMatches(rec.project)) count += 1;
        }
        return count;
    }

    fn projectAt(self: *Tui, sel: usize) ?[]const u8 {
        var n: usize = 0;
        for (self.records, 0..) |rec, i| {
            if (rec.project.len == 0 or !self.projectIsFirst(i) or !self.projectMatches(rec.project)) continue;
            if (n == sel) return rec.project;
            n += 1;
        }
        return null;
    }

    fn openProjectFilterPicker(self: *Tui) void {
        self.filtering_project = true;
        self.project_sel = 0;
        self.project_query.clearRetainingCapacity();
    }

    fn moveProjectSelection(self: *Tui, delta: isize) void {
        const count = self.projectCount();
        if (count == 0) return;
        if (delta < 0) {
            self.project_sel = if (self.project_sel == 0) count - 1 else self.project_sel - 1;
        } else {
            self.project_sel = (self.project_sel + 1) % count;
        }
    }

    fn applyProjectFilterSelection(self: *Tui) void {
        self.project_filter = self.projectAt(self.project_sel);
        self.recompute();
    }

    fn toggleProjectFilterSelection(self: *Tui) void {
        const picked = self.projectAt(self.project_sel);
        if (picked == null) {
            self.project_filter = null;
        } else if (self.project_filter) |cur| {
            self.project_filter = if (std.mem.eql(u8, cur, picked.?)) null else picked;
        } else {
            self.project_filter = picked;
        }
        self.recompute();
    }

    fn insertProjectQueryByte(self: *Tui, c: u8) void {
        self.project_query.append(self.a, c) catch oom();
        self.project_sel = 0;
    }

    fn backspaceProjectQuery(self: *Tui) void {
        if (self.project_query.items.len == 0) return;
        _ = self.project_query.pop();
        while (self.project_query.items.len > 0 and
            (self.project_query.items[self.project_query.items.len - 1] & 0xC0) == 0x80)
        {
            _ = self.project_query.pop();
        }
        self.project_sel = @min(self.project_sel, self.projectCount() -| 1);
    }

    fn writeProjectFilterPicker(self: *Tui, b: *std.ArrayList(u8), max_rows: usize) void {
        b.appendSlice(self.a, "\r\n") catch oom();
        b.appendSlice(self.a, "\x1b[1;36m> \x1b[0m") catch oom();
        b.appendSlice(self.a, self.project_query.items) catch oom();
        b.appendSlice(self.a, "\r\n\r\n") catch oom();
        const count = self.projectCount();
        // Budget for: blank, search line, blank, optional scroll info, blank, hint.
        const rows_avail = if (max_rows > 6) max_rows - 6 else 1;
        const visible = @min(rows_avail, count);
        // Same windowing strategy as pi's selectors: keep the highlighted row
        // near the middle, only pinning at the start/end of the list.
        const start = if (count <= visible) 0 else @min(self.project_sel -| (visible / 2), count - visible);
        var shown: usize = 0;
        while (shown < visible) : (shown += 1) {
            const idx = start + shown;
            const p = self.projectAt(idx);
            const focused = idx == self.project_sel;
            const label = if (p) |path| std.fs.path.basename(path) else "-";
            if (focused) {
                b.appendSlice(self.a, "\x1b[1;36m→ ") catch oom();
                b.print(self.a, "{s}\x1b[0m", .{label}) catch oom();
            } else {
                b.print(self.a, "  {s}", .{label}) catch oom();
            }
            const selected = if (p) |path| blk: {
                if (self.project_filter) |cur| break :blk std.mem.eql(u8, cur, path);
                break :blk false;
            } else self.project_filter == null;
            if (selected) b.appendSlice(self.a, " \x1b[1;32m✓\x1b[0m") catch oom();
            b.appendSlice(self.a, "\r\n") catch oom();
        }
        if (count > visible) b.print(self.a, "  \x1b[90m({d}/{d})\x1b[0m\r\n", .{ self.project_sel + 1, count }) catch oom();
        if (count == 0) b.appendSlice(self.a, "  \x1b[90mNo matching projects\x1b[0m\r\n") catch oom();
        b.appendSlice(self.a, "\r\n\x1b[90mType to search · ↑/↓ or ^p/^n move · Enter select · Space toggles/clears · Esc close\x1b[0m\r\n") catch oom();
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

fn visibleColsNoAnsi(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i += 1;
            if (i < s.len and s[i] == '[') {
                i += 1;
                while (i < s.len and (s[i] < '@' or s[i] > '~')) i += 1;
                if (i < s.len) i += 1;
            }
            continue;
        }
        if (s[i] == '\r' or s[i] == '\n') {
            i += 1;
            continue;
        }
        const d = uni.decode(s[i..]);
        cols += uni.charWidth(d.cp);
        i += d.len;
    }
    return cols;
}

test "query render keeps typed search text visible with cursor" {
    var tui = testTui();
    defer tui.query.deinit(testing.allocator);
    tui.cols = 24;
    try tui.query.appendSlice(testing.allocator, "abcdef");
    tui.query_cursor = tui.query.items.len;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    tui.writeQueryWithCursor(&out, 20);

    try testing.expect(std.mem.indexOf(u8, out.items, "abcdef") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[7m \x1b[0m") != null);
}

test "prompt line stays within terminal width" {
    var tui = testTui();
    defer tui.query.deinit(testing.allocator);
    tui.cols = 80;
    try tui.query.appendSlice(testing.allocator, "this is a deliberately long search that used to push the help text past the edge");
    tui.query_cursor = tui.query.items.len;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    tui.writePromptLine(&out);

    try testing.expect(visibleColsNoAnsi(out.items) < tui.cols);
    try testing.expect(std.mem.endsWith(u8, out.items, "\r\n"));
}

test "prompt line keeps spare column to avoid terminal autowrap" {
    var tui = testTui();
    defer tui.query.deinit(testing.allocator);
    tui.cols = 20;
    try tui.query.appendSlice(testing.allocator, "a long query that must not hit the last terminal column");
    tui.query_cursor = tui.query.items.len;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    tui.writePromptLine(&out);

    try testing.expect(visibleColsNoAnsi(out.items) < tui.cols);
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
    try testing.expectEqual(@as(usize, 21), tui.listHeight());
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
    defer tui.view_rows.deinit(testing.allocator);
    tui.recompute();
    tui.preview_scroll = 3;
    tui.result_scroll = 9;

    tui.moveDown();

    try testing.expectEqual(@as(usize, 0), tui.preview_scroll);
    try testing.expectEqual(@as(usize, 0), tui.result_scroll);
}

test "default results are grouped by last-active day" {
    var fav = favorites.Set.init(testing.allocator);
    defer fav.deinit();
    const day_old = 20_000 * seconds_per_day;
    const day_new = 20_001 * seconds_per_day;
    const records = [_]scan.Record{
        .{ .agent = .claude, .project = "p", .session = "old", .text = "same", .ts = day_old + 100 },
        .{ .agent = .codex, .project = "p", .session = "newer", .text = "same", .ts = day_new + 100 },
        .{ .agent = .pi, .project = "p", .session = "newest", .text = "same", .ts = day_new + 200 },
    };
    var tui = Tui.init(testing.allocator, undefined, &records, &fav, "");
    defer tui.hits.deinit(testing.allocator);
    defer tui.view_rows.deinit(testing.allocator);

    tui.recompute();

    try testing.expect(tui.group_by_day);
    try testing.expectEqual(@as(usize, 5), tui.view_rows.items.len);
    try testing.expectEqual(Tui.dayKey(day_new), tui.view_rows.items[0].day);
    try testing.expectEqual(@as(u32, 2), tui.hits.items[tui.view_rows.items[1].hit].idx);
    try testing.expectEqual(@as(u32, 1), tui.hits.items[tui.view_rows.items[2].hit].idx);
    try testing.expectEqual(Tui.dayKey(day_old), tui.view_rows.items[3].day);
}

test "grouped left and right arrows jump to adjacent day starts" {
    var fav = favorites.Set.init(testing.allocator);
    defer fav.deinit();
    const day_a = 20_000 * seconds_per_day;
    const day_b = 20_001 * seconds_per_day;
    const records = [_]scan.Record{
        .{ .agent = .claude, .project = "p", .session = "a", .text = "same", .ts = day_a + 1 },
        .{ .agent = .claude, .project = "p", .session = "b1", .text = "same", .ts = day_b + 20 },
        .{ .agent = .claude, .project = "p", .session = "b2", .text = "same", .ts = day_b + 10 },
    };
    var tui = Tui.init(testing.allocator, undefined, &records, &fav, "");
    defer tui.hits.deinit(testing.allocator);
    defer tui.view_rows.deinit(testing.allocator);
    tui.recompute();
    tui.sel = 1;

    try testing.expectEqual(@as(?usize, 3), tui.handleEscapeSequence("\x1b[C"));
    try testing.expectEqual(@as(u32, 0), tui.hits.items[tui.sel].idx);

    try testing.expectEqual(@as(?usize, 3), tui.handleEscapeSequence("\x1b[D"));
    try testing.expectEqual(@as(u32, 1), tui.hits.items[tui.sel].idx);
}

test "flat result row still shows compact last-active time" {
    var fav = favorites.Set.init(testing.allocator);
    defer fav.deinit();
    const records = [_]scan.Record{
        .{ .agent = .claude, .title = "Session title", .project = "p", .session = "s", .text = "recent prompt", .ts = 1_800 },
    };
    var tui = Tui.init(testing.allocator, undefined, &records, &fav, "");
    defer tui.hits.deinit(testing.allocator);
    defer tui.view_rows.deinit(testing.allocator);
    tui.group_by_day = false;
    tui.recompute();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), tui.writeResultRow(&out, 0, 40, 3_600, 2));

    try testing.expect(std.mem.indexOf(u8, out.items, "30m") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "Session title") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "recent prompt") != null);
}

test "result row title falls back to session id" {
    var fav = favorites.Set.init(testing.allocator);
    defer fav.deinit();
    const records = [_]scan.Record{
        .{ .agent = .claude, .project = "p", .session = "session-123", .text = "prompt text", .ts = 1_800 },
    };
    var tui = Tui.init(testing.allocator, undefined, &records, &fav, "");
    defer tui.hits.deinit(testing.allocator);
    defer tui.view_rows.deinit(testing.allocator);
    tui.group_by_day = false;
    tui.recompute();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = tui.writeResultRow(&out, 0, 40, 3_600, 2);

    try testing.expect(std.mem.indexOf(u8, out.items, "session-123") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "prompt text") != null);
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
    defer tui.view_rows.deinit(testing.allocator);
    tui.recompute();
    try testing.expectEqual(@as(usize, 2), tui.hits.items.len);
    try testing.expectEqual(@as(u8, 0), tui.agent_filter_mask);

    tui.openAgentFilterPicker();
    try testing.expectEqual(@as(usize, 0), tui.filter_sel);
    tui.toggleFilterSelection();
    try testing.expectEqual(@as(u8, 1), tui.agent_filter_mask);
    try testing.expectEqual(@as(usize, 1), tui.hits.items.len);
    try testing.expectEqual(scan.Agent.claude, records[tui.hits.items[0].idx].agent);

    tui.filter_sel = 3;
    tui.toggleFilterSelection();
    try testing.expectEqual(@as(u8, 9), tui.agent_filter_mask);
    try testing.expectEqual(@as(usize, 2), tui.hits.items.len);

    tui.filter_sel = 0;
    tui.toggleFilterSelection();
    try testing.expectEqual(@as(u8, 8), tui.agent_filter_mask);
    try testing.expectEqual(@as(usize, 1), tui.hits.items.len);
    try testing.expectEqual(scan.Agent.opencode, records[tui.hits.items[0].idx].agent);

    tui.filter_sel = 3;
    tui.toggleFilterSelection();
    try testing.expectEqual(@as(u8, 0), tui.agent_filter_mask);
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
