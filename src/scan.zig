const std = @import("std");
const Io = std.Io;
const json = std.json;

/// Allocation failure on the program arena is unrecoverable; crash loudly
/// rather than silently dropping records or substituting empty strings.
fn oom() noreturn {
    @panic("out of memory");
}

pub const Agent = enum {
    claude,
    codex,
    pi,
    opencode,
    cursor,
    grok,

    pub fn label(self: Agent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .pi => "pi",
            .opencode => "opencode",
            .cursor => "cursor",
            .grok => "grok",
        };
    }

    pub fn all() []const Agent {
        return &.{ .claude, .codex, .pi, .opencode, .cursor, .grok };
    }
};

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    total: u64 = 0,
    context_window: u64 = 0,
    rate_percent: f64 = 0,
    cost: f64 = 0,
};

pub const Meta = struct {
    provider: []const u8 = "",
    model: []const u8 = "",
    thinking: []const u8 = "",
    plan: []const u8 = "",
    usage: Usage = .{},
};

pub const Record = struct {
    agent: Agent,
    title: []const u8 = "",
    text: []const u8,
    project: []const u8,
    session: []const u8,
    ts: i64, // session last-active unix seconds, 0 if unknown
    meta: Meta = .{},
};

// CDXC:AgentHistorySearch 2026-06-04-23:31:
// Codex session files can total multiple gigabytes while zehn only needs extracted user prompts and session metadata at launch.
// Store a disposable derived cache under ~/.ghostex/zehn and invalidate each cached session by the source file's size and modified time so unchanged sessions do not get reparsed on every startup.
// CDXC:AgentHistorySearch 2026-06-05-00:14:
// Cursor Agent and Grok should participate in the same cross-agent history picker and resume flow.
// Cursor prompt text is read from local Cursor project agent-transcript JSONL files; matching ACP metadata is optional and only supplies cwd when present.
// Grok prompt text is read from ~/.grok/sessions/<encoded-cwd>/<session-id>/chat_history.jsonl while summary.json supplies session id, cwd, and model metadata.
// CDXC:AgentHistorySearch 2026-06-07-08:27:
// Zehn result rows and day grouping need a dependable last-active time for every session. Preserve `Record.ts` in the Codex derived cache and fall back to session file mtimes when an agent history format does not expose a timestamp per prompt.
// CDXC:AgentHistorySearch 2026-06-07-08:39:
// Result rows now show the matched prompt first and the undecorated session title/id directly under the prompt on the second line. Keep titles as explicit record metadata and preserve them through derived caches instead of deriving titles from private prompt content; Cursor must still expose its session id when ACP metadata does not provide a title.
// CDXC:AgentHistorySearch 2026-06-07-11:55:
// Codex rollout files often omit titles while `~/.codex/session_index.jsonl` stores the canonical `thread_name` by session id. Load that index before Codex records and overlay its title onto cached and freshly parsed records so Zehn does not fall back to ids when Codex has a real title.
// CDXC:AgentHistorySearch 2026-06-07-14:59:
// Claude history rows should show saved session names instead of raw ids when Claude has already indexed a title. Load `sessions-index.json` metadata from normal and profile project stores before parsing history, and sanitize display titles at ingestion so corrupt or control-bearing metadata cannot render mojibake in the result list.
// Cursor transcript directory names are iterator scratch slices, so copy them before storing as session ids. Otherwise later iteration can corrupt the id shown under Cursor prompts and the resume target attached to the row.
const codex_cache_version = 4;

const SourceStamp = struct {
    size_text: []const u8,
    mtime_text: []const u8,
};

pub const Scanner = struct {
    a: std.mem.Allocator,
    io: Io,
    home: []const u8,
    records: std.ArrayList(Record),
    claude_titles: std.StringHashMap([]const u8),
    codex_titles: std.StringHashMap([]const u8),
    /// Set when an opencode DB exists but the `sqlite3` CLI is unavailable.
    sqlite_missing: bool = false,

    pub fn init(a: std.mem.Allocator, io: Io, home: []const u8) Scanner {
        return .{
            .a = a,
            .io = io,
            .home = home,
            .records = .empty,
            .claude_titles = std.StringHashMap([]const u8).init(a),
            .codex_titles = std.StringHashMap([]const u8).init(a),
        };
    }

    fn path(self: *Scanner, comptime suffix: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}" ++ suffix, .{self.home}) catch oom();
    }

    fn readAll(self: *Scanner, file_path: []const u8) ?[]u8 {
        const dir = Io.Dir.cwd();
        return dir.readFileAlloc(self.io, file_path, self.a, .limited(64 * 1024 * 1024)) catch null;
    }

    fn add(self: *Scanner, r: Record) void {
        self.records.append(self.a, r) catch oom();
    }

    /// Extract plain text from a message `content` field that may be either a
    /// JSON string or an array of {type:"text", text:"..."} blocks.
    fn contentText(self: *Scanner, v: json.Value) ?[]const u8 {
        switch (v) {
            .string => |s| return s,
            .array => |arr| {
                var buf: std.ArrayList(u8) = .empty;
                for (arr.items) |item| {
                    if (item != .object) continue;
                    const t = item.object.get("type") orelse continue;
                    if (t != .string or !std.mem.eql(u8, t.string, "text")) continue;
                    const txt = item.object.get("text") orelse continue;
                    if (txt != .string) continue;
                    if (buf.items.len > 0) buf.append(self.a, ' ') catch oom();
                    buf.appendSlice(self.a, txt.string) catch oom();
                }
                if (buf.items.len == 0) return null;
                return buf.items;
            },
            else => return null,
        }
    }

    fn parseLine(self: *Scanner, line: []const u8) ?json.Value {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '{') return null;
        return json.parseFromSliceLeaky(json.Value, self.a, trimmed, .{}) catch null;
    }

    pub fn scanAll(self: *Scanner) void {
        self.scanClaude();
        self.scanCodex();
        self.scanPi();
        self.scanOpencode();
        self.scanCursor();
        self.scanGrok();
        self.dedup();
    }

    /// Collapse identical (agent, text) prompts, keeping the most recent
    /// occurrence (highest ts). Preserves first-seen ordering otherwise.
    pub fn dedup(self: *Scanner) void {
        var map = std.StringHashMap(usize).init(self.a);
        defer map.deinit();
        var out: std.ArrayList(Record) = .empty;
        for (self.records.items) |rec| {
            const key = std.fmt.allocPrint(self.a, "{s}\x00{s}", .{ rec.agent.label(), rec.text }) catch oom();
            if (map.get(key)) |pos| {
                if (rec.ts > out.items[pos].ts) out.items[pos] = rec;
            } else {
                map.put(key, out.items.len) catch oom();
                out.append(self.a, rec) catch oom();
            }
        }
        self.records = out;
    }

    fn scanClaude(self: *Scanner) void {
        self.loadClaudeSessionTitles();
        const p = self.path("/.claude/history.jsonl");
        const data = self.readAll(p) orelse return;
        self.parseClaudeHistory(data);
    }

    fn loadClaudeSessionTitles(self: *Scanner) void {
        self.loadClaudeProjectSessionIndexes(self.path("/.claude/projects"));
        self.loadClaudeProjectSessionIndexes(self.path("/.claude/projects2"));
        self.loadClaudeProfileSessionIndexes();
    }

    fn loadClaudeProjectSessionIndexes(self: *Scanner, base: []const u8) void {
        var root = Io.Dir.cwd().openDir(self.io, base, .{ .iterate = true }) catch return;
        defer root.close(self.io);
        var projects = root.iterate();
        while (projects.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            var project_dir = root.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
            defer project_dir.close(self.io);
            const data = project_dir.readFileAlloc(self.io, "sessions-index.json", self.a, .limited(32 * 1024 * 1024)) catch continue;
            self.parseClaudeSessionsIndex(data);
        }
    }

    fn loadClaudeProfileSessionIndexes(self: *Scanner) void {
        const base = self.path("/.claude-profiles");
        var root = Io.Dir.cwd().openDir(self.io, base, .{ .iterate = true }) catch return;
        defer root.close(self.io);
        var profiles = root.iterate();
        while (profiles.next(self.io) catch null) |profile| {
            if (profile.kind != .directory) continue;
            var profile_dir = root.openDir(self.io, profile.name, .{ .iterate = true }) catch continue;
            defer profile_dir.close(self.io);
            var projects_dir = profile_dir.openDir(self.io, "projects", .{ .iterate = true }) catch continue;
            defer projects_dir.close(self.io);
            var projects = projects_dir.iterate();
            while (projects.next(self.io) catch null) |project| {
                if (project.kind != .directory) continue;
                var project_dir = projects_dir.openDir(self.io, project.name, .{ .iterate = true }) catch continue;
                defer project_dir.close(self.io);
                const data = project_dir.readFileAlloc(self.io, "sessions-index.json", self.a, .limited(32 * 1024 * 1024)) catch continue;
                self.parseClaudeSessionsIndex(data);
            }
        }
    }

    fn parseClaudeSessionsIndex(self: *Scanner, data: []const u8) void {
        const v = json.parseFromSliceLeaky(json.Value, self.a, data, .{}) catch return;
        const entries = fieldValue(v, "entries") orelse return;
        if (entries != .array) return;
        for (entries.array.items) |entry| {
            const session_id = stringField(entry, "sessionId") orelse stringField(entry, "id") orelse continue;
            const title = titleFromFields(entry, &.{ "customTitle", "agentName", "summary", "slug", "title" }) orelse continue;
            self.putClaudeTitleIfAbsent(session_id, title);
        }
    }

    fn putClaudeTitleIfAbsent(self: *Scanner, session_id: []const u8, title: []const u8) void {
        if (cleanTitle(session_id) == null) return;
        const safe_title = cleanTitle(title) orelse return;
        if (self.claude_titles.contains(session_id)) return;
        self.claude_titles.put(session_id, safe_title) catch oom();
    }

    fn claudeTitleForSession(self: *Scanner, session_id: []const u8) ?[]const u8 {
        if (session_id.len == 0) return null;
        return self.claude_titles.get(session_id);
    }

    /// Parse `~/.claude/history.jsonl` content.
    pub fn parseClaudeHistory(self: *Scanner, data: []const u8) void {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const o = v.object;
            const disp = o.get("display") orelse continue;
            if (disp != .string or disp.string.len == 0) continue;
            const proj = if (o.get("project")) |x| (if (x == .string) x.string else "") else "";
            const sess = if (o.get("sessionId")) |x| (if (x == .string) x.string else "") else "";
            var ts: i64 = 0;
            if (o.get("timestamp")) |x| if (x == .integer) {
                ts = @divTrunc(x.integer, 1000);
            };
            // No copy: the JSON strings live in the arena (alongside the
            // file buffer) and persist for the program's lifetime.
            self.add(.{
                .agent = .claude,
                .title = titleFromObject(v) orelse self.claudeTitleForSession(sess) orelse "",
                .text = disp.string,
                .project = proj,
                .session = sess,
                .ts = ts,
            });
        }
    }

    fn scanCodex(self: *Scanner) void {
        self.loadCodexSessionIndexTitles();
        const p = self.path("/.codex/history.jsonl");
        if (self.readAll(p)) |data| self.parseCodexHistory(data);
        self.scanCodexSessions();
    }

    fn loadCodexSessionIndexTitles(self: *Scanner) void {
        const p = self.path("/.codex/session_index.jsonl");
        const data = self.readAll(p) orelse return;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            const session_id = stringField(v, "id") orelse continue;
            if (session_id.len == 0) continue;
            const title = titleFromObject(v) orelse continue;
            self.codex_titles.put(session_id, title) catch oom();
        }
    }

    fn codexTitleForSession(self: *Scanner, session_id: []const u8) ?[]const u8 {
        if (session_id.len == 0) return null;
        return self.codex_titles.get(session_id);
    }

    fn scanCodexSessions(self: *Scanner) void {
        const base = self.path("/.codex/sessions");
        var root = Io.Dir.cwd().openDir(self.io, base, .{ .iterate = true }) catch return;
        defer root.close(self.io);
        var years = root.iterate();
        while (years.next(self.io) catch null) |ye| {
            if (ye.kind != .directory) continue;
            var yd = root.openDir(self.io, ye.name, .{ .iterate = true }) catch continue;
            defer yd.close(self.io);
            var months = yd.iterate();
            while (months.next(self.io) catch null) |me| {
                if (me.kind != .directory) continue;
                var md = yd.openDir(self.io, me.name, .{ .iterate = true }) catch continue;
                defer md.close(self.io);
                var days = md.iterate();
                while (days.next(self.io) catch null) |de| {
                    if (de.kind != .directory) continue;
                    var dd = md.openDir(self.io, de.name, .{ .iterate = true }) catch continue;
                    defer dd.close(self.io);
                    var files = dd.iterate();
                    while (files.next(self.io) catch null) |fe| {
                        if (fe.kind != .file or !std.mem.endsWith(u8, fe.name, ".jsonl")) continue;
                        const full = std.fmt.allocPrint(self.a, "{s}/{s}/{s}/{s}/{s}", .{ base, ye.name, me.name, de.name, fe.name }) catch continue;
                        self.scanCodexSessionCached(full);
                    }
                }
            }
        }
    }

    fn scanCodexSessionCached(self: *Scanner, source_path: []const u8) void {
        const stat = Io.Dir.cwd().statFile(self.io, source_path, .{}) catch return;
        const fallback_ts = timestampSeconds(stat.mtime);
        const stamp = self.stampFromStat(stat) orelse {
            _ = self.scanCodexSessionUncached(source_path, fallback_ts);
            return;
        };
        const cache_path = self.codexCachePath(source_path) orelse {
            _ = self.scanCodexSessionUncached(source_path, fallback_ts);
            return;
        };
        if (self.readAll(cache_path)) |data| {
            if (self.parseCodexCache(data, source_path, stamp)) return;
        }
        const record_start = self.records.items.len;
        if (self.scanCodexSessionUncached(source_path, fallback_ts)) {
            self.saveCodexCache(cache_path, source_path, stamp, self.records.items[record_start..]);
        }
    }

    fn scanCodexSessionUncached(self: *Scanner, source_path: []const u8, fallback_ts: i64) bool {
        const data = self.readAll(source_path) orelse return false;
        self.parseCodexSessionWithLastActive(data, fallback_ts);
        return true;
    }

    fn stampFromStat(self: *Scanner, stat: Io.File.Stat) ?SourceStamp {
        return .{
            .size_text = std.fmt.allocPrint(self.a, "{d}", .{stat.size}) catch return null,
            .mtime_text = std.fmt.allocPrint(self.a, "{d}", .{stat.mtime.nanoseconds}) catch return null,
        };
    }

    fn codexCachePath(self: *Scanner, source_path: []const u8) ?[]const u8 {
        var h = std.hash.Wyhash.init(0);
        h.update(source_path);
        const id = h.final();
        return std.fmt.allocPrint(self.a, "{s}/.ghostex/zehn/codex-sessions-v4/{x:0>16}.jsonl", .{ self.home, id }) catch null;
    }

    fn saveCodexCache(self: *Scanner, cache_path: []const u8, source_path: []const u8, stamp: SourceStamp, records: []const Record) void {
        const bytes = self.buildCodexCache(source_path, stamp, records) catch return;
        if (std.fs.path.dirname(cache_path)) |dir| {
            Io.Dir.cwd().createDirPath(self.io, dir) catch return;
        }
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = cache_path, .data = bytes }) catch {};
    }

    fn buildCodexCache(self: *Scanner, source_path: []const u8, stamp: SourceStamp, records: []const Record) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.a);
        try buf.print(self.a, "{f}\n", .{json.fmt(.{
            .kind = "header",
            .version = codex_cache_version,
            .source = source_path,
            .source_size = stamp.size_text,
            .source_mtime_ns = stamp.mtime_text,
        }, .{})});
        for (records) |rec| {
            try buf.print(self.a, "{f}\n", .{json.fmt(.{
                .kind = "record",
                .title = rec.title,
                .text = rec.text,
                .project = rec.project,
                .session = rec.session,
                .ts = rec.ts,
                .provider = rec.meta.provider,
                .model = rec.meta.model,
                .thinking = rec.meta.thinking,
                .plan = rec.meta.plan,
                .input = rec.meta.usage.input,
                .output = rec.meta.usage.output,
                .cache_read = rec.meta.usage.cache_read,
                .cache_write = rec.meta.usage.cache_write,
                .total = rec.meta.usage.total,
                .context_window = rec.meta.usage.context_window,
                .rate_percent = rec.meta.usage.rate_percent,
                .cost = rec.meta.usage.cost,
            }, .{})});
        }
        try buf.print(self.a, "{f}\n", .{json.fmt(.{ .kind = "footer" }, .{})});
        return buf.toOwnedSlice(self.a);
    }

    fn parseCodexCache(self: *Scanner, data: []const u8, source_path: []const u8, stamp: SourceStamp) bool {
        const record_start = self.records.items.len;
        var it = std.mem.splitScalar(u8, data, '\n');
        const header_line = it.next() orelse return false;
        const header = self.parseLine(header_line) orelse return false;
        if (!self.codexCacheHeaderMatches(header, source_path, stamp)) return false;

        var saw_footer = false;
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const kind = stringField(v, "kind") orelse continue;
            if (std.mem.eql(u8, kind, "footer")) {
                saw_footer = true;
                break;
            }
            if (!std.mem.eql(u8, kind, "record")) continue;
            const text = stringField(v, "text") orelse continue;
            if (text.len == 0) continue;
            const session = stringField(v, "session") orelse "";
            self.add(.{
                .agent = .codex,
                .title = self.codexTitleForSession(session) orelse stringField(v, "title") orelse "",
                .text = text,
                .project = stringField(v, "project") orelse "",
                .session = session,
                .ts = timestampValue(fieldValue(v, "ts") orelse .{ .integer = 0 }),
                .meta = .{
                    .provider = stringField(v, "provider") orelse "",
                    .model = stringField(v, "model") orelse "",
                    .thinking = stringField(v, "thinking") orelse "",
                    .plan = stringField(v, "plan") orelse "",
                    .usage = .{
                        .input = intVal(fieldValue(v, "input") orelse .{ .integer = 0 }),
                        .output = intVal(fieldValue(v, "output") orelse .{ .integer = 0 }),
                        .cache_read = intVal(fieldValue(v, "cache_read") orelse .{ .integer = 0 }),
                        .cache_write = intVal(fieldValue(v, "cache_write") orelse .{ .integer = 0 }),
                        .total = intVal(fieldValue(v, "total") orelse .{ .integer = 0 }),
                        .context_window = intVal(fieldValue(v, "context_window") orelse .{ .integer = 0 }),
                        .rate_percent = floatVal(fieldValue(v, "rate_percent") orelse .{ .integer = 0 }),
                        .cost = floatVal(fieldValue(v, "cost") orelse .{ .integer = 0 }),
                    },
                },
            });
        }
        if (saw_footer) return true;
        self.records.shrinkRetainingCapacity(record_start);
        return false;
    }

    fn codexCacheHeaderMatches(_: *Scanner, v: json.Value, source_path: []const u8, stamp: SourceStamp) bool {
        if (!std.mem.eql(u8, stringField(v, "kind") orelse return false, "header")) return false;
        const version = fieldValue(v, "version") orelse return false;
        if (version != .integer or version.integer != codex_cache_version) return false;
        if (!std.mem.eql(u8, stringField(v, "source") orelse return false, source_path)) return false;
        if (!std.mem.eql(u8, stringField(v, "source_size") orelse return false, stamp.size_text)) return false;
        if (!std.mem.eql(u8, stringField(v, "source_mtime_ns") orelse return false, stamp.mtime_text)) return false;
        return true;
    }

    /// Parse `~/.codex/history.jsonl` content.
    pub fn parseCodexHistory(self: *Scanner, data: []const u8) void {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const o = v.object;
            const txt = o.get("text") orelse continue;
            if (txt != .string or txt.string.len == 0) continue;
            const sess = if (o.get("session_id")) |x| (if (x == .string) x.string else "") else "";
            var ts: i64 = 0;
            if (o.get("ts")) |x| if (x == .integer) {
                ts = x.integer;
            };
            self.add(.{
                .agent = .codex,
                .title = self.codexTitleForSession(sess) orelse titleFromObject(v) orelse "",
                .text = txt.string,
                .project = "",
                .session = sess,
                .ts = ts,
            });
        }
    }

    pub fn parseCodexSession(self: *Scanner, data: []const u8) void {
        self.parseCodexSessionWithLastActive(data, 0);
    }

    fn parseCodexSessionWithLastActive(self: *Scanner, data: []const u8, fallback_ts: i64) void {
        var cwd: []const u8 = "";
        var session_id: []const u8 = "";
        var session_title: []const u8 = "";
        var meta: Meta = .{};
        const record_start = self.records.items.len;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const line_ts = timestampFromObject(v);
            const o = v.object;
            const typ = o.get("type") orelse continue;
            if (typ != .string) continue;
            if (std.mem.eql(u8, typ.string, "session_meta")) {
                const payload = o.get("payload") orelse continue;
                if (payload != .object) continue;
                if (payload.object.get("cwd")) |x| if (x == .string) {
                    cwd = x.string;
                };
                if (payload.object.get("id")) |x| if (x == .string) {
                    session_id = x.string;
                    if (self.codexTitleForSession(session_id)) |title| {
                        session_title = title;
                        self.applyTitleToSessionRecords(record_start, session_title);
                    }
                };
                if (session_title.len == 0) if (titleFromObject(payload)) |title| {
                    session_title = title;
                    self.applyTitleToSessionRecords(record_start, session_title);
                };
                if (payload.object.get("model_provider")) |x| if (x == .string) {
                    meta.provider = x.string;
                };
                self.applyMetaToSessionRecords(record_start, meta);
                continue;
            }
            if (std.mem.eql(u8, typ.string, "event_msg")) {
                const payload = o.get("payload") orelse continue;
                if (payload != .object) continue;
                const ptype = payload.object.get("type") orelse continue;
                if (ptype != .string or !std.mem.eql(u8, ptype.string, "token_count")) continue;
                if (payload.object.get("info")) |info| if (info == .object) {
                    if (info.object.get("model_context_window")) |x| meta.usage.context_window = intVal(x);
                    if (info.object.get("total_token_usage")) |u| if (u == .object) {
                        meta.usage.input = if (u.object.get("input_tokens")) |x| intVal(x) else meta.usage.input;
                        meta.usage.output = if (u.object.get("output_tokens")) |x| intVal(x) else meta.usage.output;
                        meta.usage.cache_read = if (u.object.get("cached_input_tokens")) |x| intVal(x) else meta.usage.cache_read;
                        meta.usage.total = if (u.object.get("total_tokens")) |x| intVal(x) else meta.usage.total;
                    };
                };
                if (payload.object.get("rate_limits")) |rl| if (rl == .object) {
                    if (rl.object.get("primary")) |primary| if (primary == .object) {
                        meta.usage.rate_percent = if (primary.object.get("used_percent")) |x| floatVal(x) else meta.usage.rate_percent;
                    };
                    if (rl.object.get("plan_type")) |x| if (x == .string) {
                        meta.plan = x.string;
                    };
                };
                self.applyMetaToSessionRecords(record_start, meta);
                continue;
            }
            if (!std.mem.eql(u8, typ.string, "response_item")) continue;
            const payload = o.get("payload") orelse continue;
            if (payload != .object) continue;
            const ptype = payload.object.get("type") orelse continue;
            if (ptype != .string or !std.mem.eql(u8, ptype.string, "message")) continue;
            const role = payload.object.get("role") orelse continue;
            if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
            const content = payload.object.get("content") orelse continue;
            const text = self.contentText(content) orelse continue;
            if (text.len == 0 or std.mem.startsWith(u8, text, "<")) continue;
            self.add(.{ .agent = .codex, .title = session_title, .text = text, .project = cwd, .session = session_id, .ts = if (fallback_ts > 0) fallback_ts else line_ts, .meta = meta });
        }
    }

    fn scanPi(self: *Scanner) void {
        const base = self.path("/.pi/agent/sessions");
        var root = Io.Dir.cwd().openDir(self.io, base, .{ .iterate = true }) catch return;
        defer root.close(self.io);
        var rit = root.iterate();
        while (rit.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            var sub = root.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(self.io);
            var sit = sub.iterate();
            while (sit.next(self.io) catch null) |fe| {
                if (fe.kind != .file) continue;
                if (!std.mem.endsWith(u8, fe.name, ".jsonl")) continue;
                const full = std.fmt.allocPrint(self.a, "{s}/{s}/{s}", .{ base, entry.name, fe.name }) catch continue;
                self.scanPiFile(full);
            }
        }
    }

    fn scanPiFile(self: *Scanner, file_path: []const u8) void {
        const fallback_ts = if (Io.Dir.cwd().statFile(self.io, file_path, .{})) |stat| timestampSeconds(stat.mtime) else |_| 0;
        const data = self.readAll(file_path) orelse return;
        self.parsePiSessionWithLastActive(data, fallback_ts);
    }

    fn scanCursor(self: *Scanner) void {
        const base = self.path("/.cursor/projects");
        var root = Io.Dir.cwd().openDir(self.io, base, .{ .iterate = true }) catch return;
        defer root.close(self.io);
        var projects = root.iterate();
        while (projects.next(self.io) catch null) |pe| {
            if (pe.kind != .directory) continue;
            var project_dir = root.openDir(self.io, pe.name, .{ .iterate = true }) catch continue;
            defer project_dir.close(self.io);
            var transcripts = project_dir.openDir(self.io, "agent-transcripts", .{ .iterate = true }) catch continue;
            defer transcripts.close(self.io);
            var sessions = transcripts.iterate();
            while (sessions.next(self.io) catch null) |se| {
                if (se.kind != .directory) continue;
                const session_id = self.a.dupe(u8, se.name) catch oom();
                const file_name = std.fmt.allocPrint(self.a, "{s}.jsonl", .{session_id}) catch continue;
                var session_dir = transcripts.openDir(self.io, session_id, .{ .iterate = true }) catch continue;
                defer session_dir.close(self.io);
                const stat = session_dir.statFile(self.io, file_name, .{}) catch continue;
                const data = session_dir.readFileAlloc(self.io, file_name, self.a, .limited(64 * 1024 * 1024)) catch continue;
                const info = self.cursorInfoForSession(session_id);
                self.parseCursorTranscript(data, info.project, info.title, session_id, timestampSeconds(stat.mtime));
            }
        }
    }

    const CursorInfo = struct {
        project: []const u8 = "",
        title: []const u8 = "",
    };

    fn cursorInfoForSession(self: *Scanner, session_id: []const u8) CursorInfo {
        const meta_path = std.fmt.allocPrint(self.a, "{s}/.cursor/acp-sessions/{s}/meta.json", .{ self.home, session_id }) catch return .{};
        const data = self.readAll(meta_path) orelse return .{};
        const v = json.parseFromSliceLeaky(json.Value, self.a, data, .{}) catch return .{};
        return .{ .project = stringField(v, "cwd") orelse "", .title = titleFromFields(v, &.{ "thread_name", "threadName", "title", "session_title", "sessionTitle" }) orelse "" };
    }

    /// Parse Cursor Agent transcript JSONL from ~/.cursor/projects/*/agent-transcripts.
    pub fn parseCursorTranscript(self: *Scanner, data: []const u8, project: []const u8, title: []const u8, session_id: []const u8, ts: i64) void {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const role = stringField(v, "role") orelse continue;
            if (!std.mem.eql(u8, role, "user")) continue;
            const msg = fieldValue(v, "message") orelse continue;
            if (msg != .object) continue;
            const content = fieldValue(msg, "content") orelse continue;
            const text = self.contentText(content) orelse continue;
            if (text.len == 0) continue;
            self.add(.{ .agent = .cursor, .title = title, .text = text, .project = project, .session = session_id, .ts = ts });
        }
    }

    fn scanGrok(self: *Scanner) void {
        const base = self.path("/.grok/sessions");
        var root = Io.Dir.cwd().openDir(self.io, base, .{ .iterate = true }) catch return;
        defer root.close(self.io);
        var projects = root.iterate();
        while (projects.next(self.io) catch null) |pe| {
            if (pe.kind != .directory) continue;
            var project_dir = root.openDir(self.io, pe.name, .{ .iterate = true }) catch continue;
            defer project_dir.close(self.io);
            var sessions = project_dir.iterate();
            while (sessions.next(self.io) catch null) |se| {
                if (se.kind != .directory) continue;
                var session_dir = project_dir.openDir(self.io, se.name, .{ .iterate = true }) catch continue;
                defer session_dir.close(self.io);
                const summary_data = session_dir.readFileAlloc(self.io, "summary.json", self.a, .limited(8 * 1024 * 1024)) catch continue;
                var info = self.parseGrokSummary(summary_data, se.name);
                const stat = session_dir.statFile(self.io, "chat_history.jsonl", .{}) catch continue;
                const data = session_dir.readFileAlloc(self.io, "chat_history.jsonl", self.a, .limited(64 * 1024 * 1024)) catch continue;
                if (info.ts == 0) info.ts = timestampSeconds(stat.mtime);
                self.parseGrokChatHistory(data, info);
            }
        }
    }

    const GrokInfo = struct {
        session: []const u8,
        project: []const u8 = "",
        title: []const u8 = "",
        model: []const u8 = "",
        ts: i64 = 0,
    };

    fn parseGrokSummary(self: *Scanner, data: []const u8, fallback_session: []const u8) GrokInfo {
        const v = json.parseFromSliceLeaky(json.Value, self.a, data, .{}) catch return .{ .session = fallback_session };
        var info = GrokInfo{
            .session = stringField(fieldValue(v, "info") orelse .{ .object = .empty }, "id") orelse stringField(v, "id") orelse fallback_session,
            .project = stringField(fieldValue(v, "info") orelse .{ .object = .empty }, "cwd") orelse stringField(v, "git_root_dir") orelse "",
            .title = titleFromObject(v) orelse titleFromObject(fieldValue(v, "info") orelse .{ .object = .empty }) orelse "",
            .model = stringField(v, "current_model_id") orelse "",
        };
        if (stringField(v, "updated_at")) |updated| info.ts = parseIso8601Seconds(updated);
        return info;
    }

    /// Parse Grok chat history JSONL from ~/.grok/sessions/*/*/chat_history.jsonl.
    pub fn parseGrokChatHistory(self: *Scanner, data: []const u8, info: GrokInfo) void {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const typ = stringField(v, "type") orelse continue;
            if (!std.mem.eql(u8, typ, "user")) continue;
            const content = fieldValue(v, "content") orelse continue;
            const text = self.contentText(content) orelse continue;
            if (text.len == 0) continue;
            self.add(.{ .agent = .grok, .title = info.title, .text = text, .project = info.project, .session = info.session, .ts = info.ts, .meta = .{ .provider = "xai", .model = info.model } });
        }
    }

    fn intVal(v: json.Value) u64 {
        return switch (v) {
            .integer => |n| if (n > 0) @intCast(n) else 0,
            .float => |f| if (f > 0) @intFromFloat(f) else 0,
            else => 0,
        };
    }

    fn floatVal(v: json.Value) f64 {
        return switch (v) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            else => 0,
        };
    }

    fn fieldValue(v: json.Value, name: []const u8) ?json.Value {
        if (v != .object) return null;
        return v.object.get(name);
    }

    fn timestampFromObject(v: json.Value) i64 {
        for ([_][]const u8{ "updated_at", "updatedAt", "timestamp", "created_at", "createdAt", "ts" }) |name| {
            const ts = timestampValue(fieldValue(v, name) orelse continue);
            if (ts > 0) return ts;
        }
        if (fieldValue(v, "time")) |time| {
            const ts = timestampValue(time);
            if (ts > 0) return ts;
        }
        return 0;
    }

    fn timestampValue(v: json.Value) i64 {
        return switch (v) {
            .integer => |n| normalizeTimestamp(n),
            .float => |n| normalizeTimestamp(@intFromFloat(n)),
            .string => |s| parseTimestampString(s),
            .object => blk: {
                for ([_][]const u8{ "updated", "updated_at", "updatedAt", "created", "created_at", "createdAt", "timestamp", "ts" }) |name| {
                    const ts = timestampValue(fieldValue(v, name) orelse continue);
                    if (ts > 0) break :blk ts;
                }
                break :blk 0;
            },
            else => 0,
        };
    }

    fn normalizeTimestamp(n: i64) i64 {
        if (n <= 0) return 0;
        return if (n > 10_000_000_000) @divTrunc(n, 1000) else n;
    }

    fn parseTimestampString(s: []const u8) i64 {
        if (s.len == 0) return 0;
        if (std.fmt.parseInt(i64, s, 10)) |n| return normalizeTimestamp(n) else |_| {}
        return parseIso8601Seconds(s);
    }

    fn stringField(v: json.Value, name: []const u8) ?[]const u8 {
        const x = fieldValue(v, name) orelse return null;
        if (x != .string) return null;
        return x.string;
    }

    fn titleFromFields(v: json.Value, fields: []const []const u8) ?[]const u8 {
        if (v != .object) return null;
        for (fields) |name| {
            const title = stringField(v, name) orelse continue;
            if (cleanTitle(title)) |safe| return safe;
        }
        return null;
    }

    fn titleFromObject(v: json.Value) ?[]const u8 {
        return titleFromFields(v, &.{ "thread_name", "threadName", "title", "session_title", "sessionTitle", "name" });
    }

    fn cleanTitle(title: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0) return null;
        if (!std.unicode.utf8ValidateSlice(trimmed)) return null;
        var i: usize = 0;
        while (i < trimmed.len) : (i += 1) {
            const c = trimmed[i];
            if (c < 0x20 or c == 0x7f) return null;
            if (i + 3 <= trimmed.len and trimmed[i] == 0xef and trimmed[i + 1] == 0xbf and trimmed[i + 2] == 0xbd) return null;
        }
        return trimmed;
    }

    fn timestampSeconds(ts: Io.Timestamp) i64 {
        return @intCast(@divTrunc(ts.nanoseconds, 1_000_000_000));
    }

    fn parseIso8601Seconds(s: []const u8) i64 {
        if (s.len < 19) return 0;
        const year = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
        const month = std.fmt.parseInt(u8, s[5..7], 10) catch return 0;
        const day = std.fmt.parseInt(u8, s[8..10], 10) catch return 0;
        const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return 0;
        const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return 0;
        const second = std.fmt.parseInt(u8, s[17..19], 10) catch return 0;
        const days = daysFromCivil(year, month, day);
        return days * 86_400 + @as(i64, hour) * 3_600 + @as(i64, minute) * 60 + @as(i64, second);
    }

    fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
        var y = year;
        const m: i64 = month;
        y -= @intFromBool(m <= 2);
        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const mp = m + if (m > 2) @as(i64, -3) else 9;
        const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, day) - 1;
        const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    fn applyMetaToSessionRecords(self: *Scanner, start: usize, meta: Meta) void {
        for (self.records.items[start..]) |*rec| rec.meta = meta;
    }

    fn applyTitleToSessionRecords(self: *Scanner, start: usize, title: []const u8) void {
        for (self.records.items[start..]) |*rec| rec.title = title;
    }

    /// Parse a single pi session `.jsonl` file content.
    pub fn parsePiSession(self: *Scanner, data: []const u8) void {
        self.parsePiSessionWithLastActive(data, 0);
    }

    fn parsePiSessionWithLastActive(self: *Scanner, data: []const u8, fallback_ts: i64) void {
        var cwd: []const u8 = "";
        var session_id: []const u8 = "";
        var session_title: []const u8 = "";
        var meta: Meta = .{};
        var session_ts = fallback_ts;
        const record_start = self.records.items.len;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            // Only session headers and user messages yield records. Skip the
            // far larger/more numerous assistant & tool lines before paying for
            // a full JSON parse. pi writes compact JSON with `type` first and
            // the role marker near the start, so bound the scan to the line
            // head — otherwise we'd scan multi-KB assistant bodies in full.
            const head = line[0..@min(line.len, 128)];
            const keep = std.mem.startsWith(u8, line, "{\"type\":\"session\"") or
                std.mem.startsWith(u8, line, "{\"type\":\"model_change\"") or
                std.mem.startsWith(u8, line, "{\"type\":\"thinking_level_change\"") or
                std.mem.indexOf(u8, head, "\"role\":\"user\"") != null or
                std.mem.indexOf(u8, head, "\"role\":\"assistant\"") != null;
            if (!keep) continue;
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const line_ts = timestampFromObject(v);
            const o = v.object;
            const typ = o.get("type") orelse continue;
            if (typ != .string) continue;
            if (std.mem.eql(u8, typ.string, "session")) {
                if (session_ts == 0 and line_ts > 0) session_ts = line_ts;
                if (o.get("cwd")) |x| if (x == .string) {
                    cwd = x.string;
                };
                if (o.get("id")) |x| if (x == .string) {
                    session_id = x.string;
                };
                if (titleFromObject(v)) |title| {
                    session_title = title;
                    self.applyTitleToSessionRecords(record_start, session_title);
                }
                continue;
            }
            if (std.mem.eql(u8, typ.string, "model_change")) {
                if (o.get("provider")) |x| if (x == .string) {
                    meta.provider = x.string;
                };
                if (o.get("modelId")) |x| if (x == .string) {
                    meta.model = x.string;
                };
                self.applyMetaToSessionRecords(record_start, meta);
                continue;
            }
            if (std.mem.eql(u8, typ.string, "thinking_level_change")) {
                if (o.get("thinkingLevel")) |x| if (x == .string) {
                    meta.thinking = x.string;
                };
                self.applyMetaToSessionRecords(record_start, meta);
                continue;
            }
            if (!std.mem.eql(u8, typ.string, "message")) continue;
            const msg = o.get("message") orelse continue;
            if (msg != .object) continue;
            const role = msg.object.get("role") orelse continue;
            if (role != .string) continue;
            if (std.mem.eql(u8, role.string, "assistant")) {
                if (msg.object.get("provider")) |x| if (x == .string) {
                    meta.provider = x.string;
                };
                if (msg.object.get("model")) |x| if (x == .string) {
                    meta.model = x.string;
                };
                if (msg.object.get("usage")) |u| if (u == .object) {
                    meta.usage.input += if (u.object.get("input")) |x| intVal(x) else 0;
                    meta.usage.output += if (u.object.get("output")) |x| intVal(x) else 0;
                    meta.usage.cache_read += if (u.object.get("cacheRead")) |x| intVal(x) else 0;
                    meta.usage.cache_write += if (u.object.get("cacheWrite")) |x| intVal(x) else 0;
                    meta.usage.total += if (u.object.get("totalTokens")) |x| intVal(x) else 0;
                    if (u.object.get("cost")) |cost| if (cost == .object) {
                        meta.usage.cost += if (cost.object.get("total")) |x| floatVal(x) else 0;
                    };
                };
                self.applyMetaToSessionRecords(record_start, meta);
                continue;
            }
            if (!std.mem.eql(u8, role.string, "user")) continue;
            const content = msg.object.get("content") orelse continue;
            const text = self.contentText(content) orelse continue;
            if (text.len == 0) continue;
            self.add(.{
                .agent = .pi,
                .title = session_title,
                .text = text,
                .project = cwd,
                .session = session_id,
                .ts = if (session_ts > 0) session_ts else line_ts,
                .meta = meta,
            });
        }
    }

    const opencode_query =
        "SELECT json_object(" ++
        "'role',json_extract(m.data,'$.role')," ++
        "'type',json_extract(p.data,'$.type')," ++
        "'text',json_extract(p.data,'$.text')," ++
        "'title',null," ++
        "'provider',json_extract(m.data,'$.model.providerID')," ++
        "'model',json_extract(m.data,'$.model.modelID')," ++
        "'project',s.directory," ++
        "'session',s.id," ++
        "'ts',coalesce(json_extract(m.data,'$.time.updated'),json_extract(m.data,'$.time.created'),json_extract(m.data,'$.updated_at'),json_extract(m.data,'$.created_at'),json_extract(m.data,'$.updatedAt'),json_extract(m.data,'$.createdAt'),json_extract(m.data,'$.timestamp'))) " ++
        "FROM part p " ++
        "JOIN message m ON p.message_id=m.id " ++
        "JOIN session s ON p.session_id=s.id " ++
        "WHERE json_extract(p.data,'$.type')='text';";

    fn scanOpencode(self: *Scanner) void {
        const db = self.path("/.local/share/opencode/opencode.db");
        self.scanOpencodeDb(db);
    }

    /// opencode stores history in SQLite; shell out to the sqlite3 CLI to emit
    /// one JSON object per user text part, then parse like the rest.
    pub fn scanOpencodeDb(self: *Scanner, db_path: []const u8) void {
        // Only attempt if the DB exists, so a missing sqlite3 only matters when
        // there is actually opencode history to read.
        const exists = blk: {
            var f = Io.Dir.cwd().openFile(self.io, db_path, .{}) catch break :blk false;
            f.close(self.io);
            break :blk true;
        };
        if (!exists) return;
        const fallback_ts = if (Io.Dir.cwd().statFile(self.io, db_path, .{})) |stat| timestampSeconds(stat.mtime) else |_| 0;
        const argv = [_][]const u8{ "sqlite3", "-batch", "-noheader", db_path, opencode_query };
        const res = std.process.run(self.a, self.io, .{ .argv = &argv }) catch |err| {
            if (err == error.FileNotFound) self.sqlite_missing = true;
            return;
        };
        if (res.term != .exited or res.term.exited != 0) return;
        self.parseOpencodeWithLastActive(res.stdout, fallback_ts);
    }

    /// Parse JSONL produced by `opencode_query` (one object per text part).
    pub fn parseOpencode(self: *Scanner, data: []const u8) void {
        self.parseOpencodeWithLastActive(data, 0);
    }

    fn parseOpencodeWithLastActive(self: *Scanner, data: []const u8, fallback_ts: i64) void {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const o = v.object;
            const role = o.get("role") orelse continue;
            if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
            const typ = o.get("type") orelse continue;
            if (typ != .string or !std.mem.eql(u8, typ.string, "text")) continue;
            const txt = o.get("text") orelse continue;
            if (txt != .string or txt.string.len == 0) continue;
            const proj = if (o.get("project")) |x| (if (x == .string) x.string else "") else "";
            const sess = if (o.get("session")) |x| (if (x == .string) x.string else "") else "";
            const provider = if (o.get("provider")) |x| (if (x == .string) x.string else "") else "";
            const model = if (o.get("model")) |x| (if (x == .string) x.string else "") else "";
            const ts = timestampValue(o.get("ts") orelse .{ .integer = 0 });
            self.add(.{
                .agent = .opencode,
                .title = titleFromObject(v) orelse "",
                .text = txt.string,
                .project = proj,
                .session = sess,
                .ts = if (ts > 0) ts else fallback_ts,
                .meta = .{ .provider = provider, .model = model },
            });
        }
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn testScanner(a: std.mem.Allocator) Scanner {
    // io/home unused by the pure parse* functions under test.
    return .{
        .a = a,
        .io = undefined,
        .home = "",
        .records = .empty,
        .claude_titles = std.StringHashMap([]const u8).init(a),
        .codex_titles = std.StringHashMap([]const u8).init(a),
    };
}

test "parse claude history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"display":"first prompt","project":"/p/one","sessionId":"s1","timestamp":1700000000000}
        \\{"display":"second","project":"/p/two","sessionId":"s2","timestamp":1700000001000}
        \\{"notdisplay":"ignored"}
        \\{"display":""}
    ;
    sc.parseClaudeHistory(data);
    try testing.expectEqual(@as(usize, 2), sc.records.items.len);
    try testing.expectEqualStrings("first prompt", sc.records.items[0].text);
    try testing.expectEqualStrings("/p/one", sc.records.items[0].project);
    try testing.expectEqualStrings("s1", sc.records.items[0].session);
    try testing.expectEqual(@as(i64, 1700000000), sc.records.items[0].ts);
    try testing.expectEqual(Agent.claude, sc.records.items[0].agent);
}

test "claude session indexes supply titles to history rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const index_data =
        \\{"entries":[{"sessionId":"s1","summary":"Saved Claude title"},{"sessionId":"s2","slug":"slug-title"},{"sessionId":"s3","summary":"Summary title","customTitle":"Custom Claude title"},{"sessionId":"bad","summary":"bad\u001b[31m"}]}
    ;
    sc.parseClaudeSessionsIndex(index_data);
    const data =
        \\{"display":"first prompt","project":"/p/one","sessionId":"s1","timestamp":1700000000000}
        \\{"display":"second prompt","project":"/p/two","sessionId":"s2","timestamp":1700000001000}
        \\{"display":"third prompt","project":"/p/three","sessionId":"s3","timestamp":1700000001500}
        \\{"display":"bad prompt","project":"/p/bad","sessionId":"bad","timestamp":1700000002000}
    ;
    sc.parseClaudeHistory(data);
    try testing.expectEqual(@as(usize, 4), sc.records.items.len);
    try testing.expectEqualStrings("Saved Claude title", sc.records.items[0].title);
    try testing.expectEqualStrings("slug-title", sc.records.items[1].title);
    try testing.expectEqualStrings("Custom Claude title", sc.records.items[2].title);
    try testing.expectEqualStrings("", sc.records.items[3].title);
}

test "display title extraction rejects control and replacement characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const control = sc.parseLine(
        \\{"title":"bad\u001b[31m"}
    ).?;
    try testing.expect(Scanner.titleFromObject(control) == null);
    const replacement = sc.parseLine(
        \\{"title":"bad\ufffdtitle"}
    ).?;
    try testing.expect(Scanner.titleFromObject(replacement) == null);
    const valid = sc.parseLine(
        \\{"title":"  Useful title  "}
    ).?;
    try testing.expectEqualStrings("Useful title", Scanner.titleFromObject(valid).?);
}

test "cursor title metadata ignores generic name field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const v = sc.parseLine(
        \\{"cwd":"/work/cursor","name":"Generic Cursor metadata name"}
    ).?;
    try testing.expect(Scanner.titleFromFields(v, &.{ "thread_name", "threadName", "title", "session_title", "sessionTitle" }) == null);
}

test "parse codex history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    try sc.codex_titles.put("abc", "Indexed Codex title");
    const data =
        \\{"session_id":"abc","ts":1779186371,"text":"hello codex"}
        \\{"session_id":"abc","ts":1779186900,"text":""}
        \\garbage line
    ;
    sc.parseCodexHistory(data);
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqualStrings("Indexed Codex title", sc.records.items[0].title);
    try testing.expectEqualStrings("hello codex", sc.records.items[0].text);
    try testing.expectEqualStrings("abc", sc.records.items[0].session);
    try testing.expectEqual(@as(i64, 1779186371), sc.records.items[0].ts);
    try testing.expectEqual(Agent.codex, sc.records.items[0].agent);
}

test "codex cache round-trips records and rejects stale source metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var writer_sc = testScanner(a);
    const stamp = SourceStamp{ .size_text = "1234", .mtime_text = "1779186371000000000" };
    const source = "/home/x/.codex/sessions/2026/06/04/session.jsonl";
    const records = [_]Record{
        .{
            .agent = .codex,
            .title = "Cached title",
            .text = "cached user prompt",
            .project = "/work/proj",
            .session = "sess-1",
            .ts = 1779186371,
            .meta = .{
                .provider = "openai",
                .model = "gpt-test",
                .plan = "plus",
                .usage = .{ .input = 10, .output = 20, .total = 30, .context_window = 200000, .rate_percent = 12.5, .cost = 0.25 },
            },
        },
    };
    const cache_data = try writer_sc.buildCodexCache(source, stamp, &records);

    var reader_sc = testScanner(a);
    try reader_sc.codex_titles.put("sess-1", "Indexed title");
    try testing.expect(reader_sc.parseCodexCache(cache_data, source, stamp));
    try testing.expectEqual(@as(usize, 1), reader_sc.records.items.len);
    const rec = reader_sc.records.items[0];
    try testing.expectEqual(Agent.codex, rec.agent);
    try testing.expectEqualStrings("Indexed title", rec.title);
    try testing.expectEqualStrings("cached user prompt", rec.text);
    try testing.expectEqualStrings("/work/proj", rec.project);
    try testing.expectEqualStrings("sess-1", rec.session);
    try testing.expectEqual(@as(i64, 1779186371), rec.ts);
    try testing.expectEqualStrings("openai", rec.meta.provider);
    try testing.expectEqual(@as(u64, 30), rec.meta.usage.total);
    try testing.expectEqual(@as(f64, 12.5), rec.meta.usage.rate_percent);

    var stale_sc = testScanner(a);
    try testing.expect(!stale_sc.parseCodexCache(cache_data, source, .{ .size_text = "9999", .mtime_text = stamp.mtime_text }));
    try testing.expectEqual(@as(usize, 0), stale_sc.records.items.len);
}

test "codex cache without footer rolls back appended records" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    try sc.records.append(sc.a, .{ .agent = .claude, .text = "keep", .project = "", .session = "old", .ts = 1 });
    const stamp = SourceStamp{ .size_text = "100", .mtime_text = "200" };
    const data =
        \\{"kind":"header","version":4,"source":"/source.jsonl","source_size":"100","source_mtime_ns":"200"}
        \\{"kind":"record","title":"Partial title","text":"partial","project":"/p","session":"s","ts":3,"provider":"","model":"","thinking":"","plan":"","input":0,"output":0,"cache_read":0,"cache_write":0,"total":0,"context_window":0,"rate_percent":0,"cost":0}
    ;
    try testing.expect(!sc.parseCodexCache(data, "/source.jsonl", stamp));
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqualStrings("keep", sc.records.items[0].text);
}

test "codex session fallback timestamp becomes session last active time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    try sc.codex_titles.put("codex-session", "Indexed Codex title");
    const data =
        \\{"type":"session_meta","payload":{"cwd":"/work/proj","id":"codex-session","title":"Codex session title"}}
        \\{"type":"response_item","timestamp":"2026-06-07T07:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"text","text":"codex prompt"}]}}
    ;
    sc.parseCodexSessionWithLastActive(data, 1770001234);
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqualStrings("Indexed Codex title", sc.records.items[0].title);
    try testing.expectEqualStrings("codex prompt", sc.records.items[0].text);
    try testing.expectEqual(@as(i64, 1770001234), sc.records.items[0].ts);
}

test "parse pi session: only user messages, session id + cwd captured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"type":"session","version":3,"id":"019e-uuid","cwd":"/work/proj","title":"Pi session title"}
        \\{"type":"model_change","modelId":"gpt"}
        \\{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi there"}]}}
        \\{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}
        \\{"type":"message","message":{"role":"user","content":"plain string content"}}
    ;
    sc.parsePiSession(data);
    try testing.expectEqual(@as(usize, 2), sc.records.items.len);
    try testing.expectEqualStrings("hi there", sc.records.items[0].text);
    try testing.expectEqualStrings("Pi session title", sc.records.items[0].title);
    try testing.expectEqualStrings("/work/proj", sc.records.items[0].project);
    try testing.expectEqualStrings("019e-uuid", sc.records.items[0].session);
    try testing.expectEqualStrings("plain string content", sc.records.items[1].text);
    try testing.expectEqual(Agent.pi, sc.records.items[0].agent);
}

test "pi session fallback timestamp becomes session last active time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"type":"session","version":3,"id":"019e-uuid","cwd":"/work/proj"}
        \\{"type":"message","message":{"role":"user","content":"hi"}}
    ;
    sc.parsePiSessionWithLastActive(data, 1770004321);
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqual(@as(i64, 1770004321), sc.records.items[0].ts);
}

test "parse opencode query output: user text parts only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"role":"user","type":"text","title":"OpenCode title","text":"opencode prompt","project":"/oc/proj","session":"oc1","ts":"1770001111"}
        \\{"role":"assistant","type":"text","text":"assistant reply","project":"/oc/proj","session":"oc1"}
        \\{"role":"user","type":"text","text":"","project":"/oc/proj","session":"oc1"}
        \\{"role":"user","type":"reasoning","text":"thinking","project":"/oc/proj","session":"oc1"}
    ;
    sc.parseOpencode(data);
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqualStrings("OpenCode title", sc.records.items[0].title);
    try testing.expectEqualStrings("opencode prompt", sc.records.items[0].text);
    try testing.expectEqualStrings("/oc/proj", sc.records.items[0].project);
    try testing.expectEqualStrings("oc1", sc.records.items[0].session);
    try testing.expectEqual(@as(i64, 1770001111), sc.records.items[0].ts);
    try testing.expectEqual(Agent.opencode, sc.records.items[0].agent);
}

test "parse cursor transcript: user message content only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"role":"user","message":{"content":[{"type":"text","text":"cursor prompt"},{"type":"tool_use","name":"ignored"}]}}
        \\{"role":"assistant","message":{"content":[{"type":"text","text":"assistant reply"}]}}
    ;
    sc.parseCursorTranscript(data, "/work/cursor", "Cursor session title", "cursor-session", 1770000000);
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqual(Agent.cursor, sc.records.items[0].agent);
    try testing.expectEqualStrings("Cursor session title", sc.records.items[0].title);
    try testing.expectEqualStrings("cursor prompt", sc.records.items[0].text);
    try testing.expectEqualStrings("/work/cursor", sc.records.items[0].project);
    try testing.expectEqualStrings("cursor-session", sc.records.items[0].session);
    try testing.expectEqual(@as(i64, 1770000000), sc.records.items[0].ts);
}

test "parse grok chat history: user content with summary metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"type":"system","content":"ignored"}
        \\{"type":"user","content":[{"type":"text","text":"grok prompt"}]}
        \\{"type":"assistant","content":"assistant reply"}
    ;
    sc.parseGrokChatHistory(data, .{ .session = "grok-session", .project = "/work/grok", .title = "Grok session title", .model = "grok-test", .ts = 1770000001 });
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqual(Agent.grok, sc.records.items[0].agent);
    try testing.expectEqualStrings("Grok session title", sc.records.items[0].title);
    try testing.expectEqualStrings("grok prompt", sc.records.items[0].text);
    try testing.expectEqualStrings("/work/grok", sc.records.items[0].project);
    try testing.expectEqualStrings("grok-session", sc.records.items[0].session);
    try testing.expectEqualStrings("grok-test", sc.records.items[0].meta.model);
    try testing.expectEqual(@as(i64, 1770000001), sc.records.items[0].ts);
}

test "dedup keeps most recent identical prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"display":"dup","project":"/p","sessionId":"old","timestamp":1000000}
        \\{"display":"unique","project":"/p","sessionId":"u","timestamp":1500000}
        \\{"display":"dup","project":"/p","sessionId":"new","timestamp":2000000}
    ;
    sc.parseClaudeHistory(data);
    try testing.expectEqual(@as(usize, 3), sc.records.items.len);
    sc.dedup();
    try testing.expectEqual(@as(usize, 2), sc.records.items.len);
    // first slot keeps "dup" but updated to the newest session/ts
    try testing.expectEqualStrings("dup", sc.records.items[0].text);
    try testing.expectEqualStrings("new", sc.records.items[0].session);
    try testing.expectEqual(@as(i64, 2000), sc.records.items[0].ts);
    try testing.expectEqualStrings("unique", sc.records.items[1].text);
}

test "dedup distinguishes same text across agents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    sc.records.append(sc.a, .{ .agent = .claude, .text = "same", .project = "", .session = "a", .ts = 1 }) catch {};
    sc.records.append(sc.a, .{ .agent = .codex, .text = "same", .project = "", .session = "b", .ts = 1 }) catch {};
    sc.dedup();
    try testing.expectEqual(@as(usize, 2), sc.records.items.len);
}

test "parse handles empty input and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    sc.parseClaudeHistory("");
    sc.parseCodexHistory("\n\n  \n");
    sc.parsePiSession("\n");
    sc.parseOpencode("");
    try testing.expectEqual(@as(usize, 0), sc.records.items.len);
}
