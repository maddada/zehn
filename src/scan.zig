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

    pub fn label(self: Agent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .pi => "pi",
            .opencode => "opencode",
        };
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
    text: []const u8,
    project: []const u8,
    session: []const u8,
    ts: i64, // unix seconds, 0 if unknown
    meta: Meta = .{},
};

// CDXC:AgentHistorySearch 2026-06-04-23:31:
// Codex session files can total multiple gigabytes while zehn only needs extracted user prompts and session metadata at launch.
// Store a disposable derived cache under ~/.ghostex/zehn and invalidate each cached session by the source file's size and modified time so unchanged sessions do not get reparsed on every startup.
const codex_cache_version = 1;

const SourceStamp = struct {
    size_text: []const u8,
    mtime_text: []const u8,
};

pub const Scanner = struct {
    a: std.mem.Allocator,
    io: Io,
    home: []const u8,
    records: std.ArrayList(Record),
    /// Set when an opencode DB exists but the `sqlite3` CLI is unavailable.
    sqlite_missing: bool = false,

    pub fn init(a: std.mem.Allocator, io: Io, home: []const u8) Scanner {
        return .{ .a = a, .io = io, .home = home, .records = .empty };
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
        const p = self.path("/.claude/history.jsonl");
        const data = self.readAll(p) orelse return;
        self.parseClaudeHistory(data);
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
                .text = disp.string,
                .project = proj,
                .session = sess,
                .ts = ts,
            });
        }
    }

    fn scanCodex(self: *Scanner) void {
        const p = self.path("/.codex/history.jsonl");
        if (self.readAll(p)) |data| self.parseCodexHistory(data);
        self.scanCodexSessions();
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
        const stamp = self.stampFromStat(stat) orelse {
            _ = self.scanCodexSessionUncached(source_path);
            return;
        };
        const cache_path = self.codexCachePath(source_path) orelse {
            _ = self.scanCodexSessionUncached(source_path);
            return;
        };
        if (self.readAll(cache_path)) |data| {
            if (self.parseCodexCache(data, source_path, stamp)) return;
        }
        const record_start = self.records.items.len;
        if (self.scanCodexSessionUncached(source_path)) {
            self.saveCodexCache(cache_path, source_path, stamp, self.records.items[record_start..]);
        }
    }

    fn scanCodexSessionUncached(self: *Scanner, source_path: []const u8) bool {
        const data = self.readAll(source_path) orelse return false;
        self.parseCodexSession(data);
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
        return std.fmt.allocPrint(self.a, "{s}/.ghostex/zehn/codex-sessions-v1/{x:0>16}.jsonl", .{ self.home, id }) catch null;
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
                .text = rec.text,
                .project = rec.project,
                .session = rec.session,
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
            self.add(.{
                .agent = .codex,
                .text = text,
                .project = stringField(v, "project") orelse "",
                .session = stringField(v, "session") orelse "",
                .ts = 0,
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
                .text = txt.string,
                .project = "",
                .session = sess,
                .ts = ts,
            });
        }
    }

    pub fn parseCodexSession(self: *Scanner, data: []const u8) void {
        var cwd: []const u8 = "";
        var session_id: []const u8 = "";
        var meta: Meta = .{};
        const record_start = self.records.items.len;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
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
            self.add(.{ .agent = .codex, .text = text, .project = cwd, .session = session_id, .ts = 0, .meta = meta });
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
        const data = self.readAll(file_path) orelse return;
        self.parsePiSession(data);
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

    fn stringField(v: json.Value, name: []const u8) ?[]const u8 {
        const x = fieldValue(v, name) orelse return null;
        if (x != .string) return null;
        return x.string;
    }

    fn applyMetaToSessionRecords(self: *Scanner, start: usize, meta: Meta) void {
        for (self.records.items[start..]) |*rec| rec.meta = meta;
    }

    /// Parse a single pi session `.jsonl` file content.
    pub fn parsePiSession(self: *Scanner, data: []const u8) void {
        var cwd: []const u8 = "";
        var session_id: []const u8 = "";
        var meta: Meta = .{};
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
            const o = v.object;
            const typ = o.get("type") orelse continue;
            if (typ != .string) continue;
            if (std.mem.eql(u8, typ.string, "session")) {
                if (o.get("cwd")) |x| if (x == .string) {
                    cwd = x.string;
                };
                if (o.get("id")) |x| if (x == .string) {
                    session_id = x.string;
                };
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
                .text = text,
                .project = cwd,
                .session = session_id,
                .ts = 0,
                .meta = meta,
            });
        }
    }

    const opencode_query =
        "SELECT json_object(" ++
        "'role',json_extract(m.data,'$.role')," ++
        "'type',json_extract(p.data,'$.type')," ++
        "'text',json_extract(p.data,'$.text')," ++
        "'provider',json_extract(m.data,'$.model.providerID')," ++
        "'model',json_extract(m.data,'$.model.modelID')," ++
        "'project',s.directory," ++
        "'session',s.id) " ++
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
        const argv = [_][]const u8{ "sqlite3", "-batch", "-noheader", db_path, opencode_query };
        const res = std.process.run(self.a, self.io, .{ .argv = &argv }) catch |err| {
            if (err == error.FileNotFound) self.sqlite_missing = true;
            return;
        };
        if (res.term != .exited or res.term.exited != 0) return;
        self.parseOpencode(res.stdout);
    }

    /// Parse JSONL produced by `opencode_query` (one object per text part).
    pub fn parseOpencode(self: *Scanner, data: []const u8) void {
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
            self.add(.{
                .agent = .opencode,
                .text = txt.string,
                .project = proj,
                .session = sess,
                .ts = 0,
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
    return .{ .a = a, .io = undefined, .home = "", .records = .empty };
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

test "parse codex history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"session_id":"abc","ts":1779186371,"text":"hello codex"}
        \\{"session_id":"abc","ts":1779186900,"text":""}
        \\garbage line
    ;
    sc.parseCodexHistory(data);
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
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
            .text = "cached user prompt",
            .project = "/work/proj",
            .session = "sess-1",
            .ts = 0,
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
    try testing.expect(reader_sc.parseCodexCache(cache_data, source, stamp));
    try testing.expectEqual(@as(usize, 1), reader_sc.records.items.len);
    const rec = reader_sc.records.items[0];
    try testing.expectEqual(Agent.codex, rec.agent);
    try testing.expectEqualStrings("cached user prompt", rec.text);
    try testing.expectEqualStrings("/work/proj", rec.project);
    try testing.expectEqualStrings("sess-1", rec.session);
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
        \\{"kind":"header","version":1,"source":"/source.jsonl","source_size":"100","source_mtime_ns":"200"}
        \\{"kind":"record","text":"partial","project":"/p","session":"s","provider":"","model":"","thinking":"","plan":"","input":0,"output":0,"cache_read":0,"cache_write":0,"total":0,"context_window":0,"rate_percent":0,"cost":0}
    ;
    try testing.expect(!sc.parseCodexCache(data, "/source.jsonl", stamp));
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqualStrings("keep", sc.records.items[0].text);
}

test "parse pi session: only user messages, session id + cwd captured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"type":"session","version":3,"id":"019e-uuid","cwd":"/work/proj"}
        \\{"type":"model_change","modelId":"gpt"}
        \\{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi there"}]}}
        \\{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}
        \\{"type":"message","message":{"role":"user","content":"plain string content"}}
    ;
    sc.parsePiSession(data);
    try testing.expectEqual(@as(usize, 2), sc.records.items.len);
    try testing.expectEqualStrings("hi there", sc.records.items[0].text);
    try testing.expectEqualStrings("/work/proj", sc.records.items[0].project);
    try testing.expectEqualStrings("019e-uuid", sc.records.items[0].session);
    try testing.expectEqualStrings("plain string content", sc.records.items[1].text);
    try testing.expectEqual(Agent.pi, sc.records.items[0].agent);
}

test "parse opencode query output: user text parts only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sc = testScanner(arena.allocator());
    const data =
        \\{"role":"user","type":"text","text":"opencode prompt","project":"/oc/proj","session":"oc1"}
        \\{"role":"assistant","type":"text","text":"assistant reply","project":"/oc/proj","session":"oc1"}
        \\{"role":"user","type":"text","text":"","project":"/oc/proj","session":"oc1"}
        \\{"role":"user","type":"reasoning","text":"thinking","project":"/oc/proj","session":"oc1"}
    ;
    sc.parseOpencode(data);
    try testing.expectEqual(@as(usize, 1), sc.records.items.len);
    try testing.expectEqualStrings("opencode prompt", sc.records.items[0].text);
    try testing.expectEqualStrings("/oc/proj", sc.records.items[0].project);
    try testing.expectEqualStrings("oc1", sc.records.items[0].session);
    try testing.expectEqual(Agent.opencode, sc.records.items[0].agent);
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
