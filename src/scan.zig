const std = @import("std");
const Io = std.Io;
const json = std.json;

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

pub const Record = struct {
    agent: Agent,
    text: []const u8,
    project: []const u8,
    session: []const u8,
    ts: i64, // unix seconds, 0 if unknown
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
        return std.fmt.allocPrint(self.a, "{s}" ++ suffix, .{self.home}) catch "";
    }

    fn dup(self: *Scanner, s: []const u8) []const u8 {
        return self.a.dupe(u8, s) catch "";
    }

    fn readAll(self: *Scanner, file_path: []const u8) ?[]u8 {
        const dir = Io.Dir.cwd();
        return dir.readFileAlloc(self.io, file_path, self.a, .limited(64 * 1024 * 1024)) catch null;
    }

    fn add(self: *Scanner, r: Record) void {
        self.records.append(self.a, r) catch {};
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
                    if (buf.items.len > 0) buf.append(self.a, ' ') catch {};
                    buf.appendSlice(self.a, txt.string) catch {};
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
            const key = std.fmt.allocPrint(self.a, "{s}\x00{s}", .{ rec.agent.label(), rec.text }) catch {
                out.append(self.a, rec) catch {};
                continue;
            };
            if (map.get(key)) |pos| {
                if (rec.ts > out.items[pos].ts) out.items[pos] = rec;
            } else {
                map.put(key, out.items.len) catch {};
                out.append(self.a, rec) catch {};
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
            self.add(.{
                .agent = .claude,
                .text = self.dup(disp.string),
                .project = self.dup(proj),
                .session = self.dup(sess),
                .ts = ts,
            });
        }
    }

    fn scanCodex(self: *Scanner) void {
        const p = self.path("/.codex/history.jsonl");
        const data = self.readAll(p) orelse return;
        self.parseCodexHistory(data);
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
                .text = self.dup(txt.string),
                .project = "",
                .session = self.dup(sess),
                .ts = ts,
            });
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

    /// Parse a single pi session `.jsonl` file content.
    pub fn parsePiSession(self: *Scanner, data: []const u8) void {
        var cwd: []const u8 = "";
        var session_id: []const u8 = "";
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const v = self.parseLine(line) orelse continue;
            if (v != .object) continue;
            const o = v.object;
            const typ = o.get("type") orelse continue;
            if (typ != .string) continue;
            if (std.mem.eql(u8, typ.string, "session")) {
                if (o.get("cwd")) |x| if (x == .string) {
                    cwd = self.dup(x.string);
                };
                if (o.get("id")) |x| if (x == .string) {
                    session_id = self.dup(x.string);
                };
                continue;
            }
            if (!std.mem.eql(u8, typ.string, "message")) continue;
            const msg = o.get("message") orelse continue;
            if (msg != .object) continue;
            const role = msg.object.get("role") orelse continue;
            if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
            const content = msg.object.get("content") orelse continue;
            const text = self.contentText(content) orelse continue;
            if (text.len == 0) continue;
            self.add(.{
                .agent = .pi,
                .text = self.dup(text),
                .project = cwd,
                .session = session_id,
                .ts = 0,
            });
        }
    }

    const opencode_query =
        "SELECT json_object(" ++
        "'role',json_extract(m.data,'$.role')," ++
        "'type',json_extract(p.data,'$.type')," ++
        "'text',json_extract(p.data,'$.text')," ++
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
            self.add(.{
                .agent = .opencode,
                .text = self.dup(txt.string),
                .project = self.dup(proj),
                .session = self.dup(sess),
                .ts = 0,
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
