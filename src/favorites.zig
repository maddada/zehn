const std = @import("std");
const Io = std.Io;

/// Favorites are stored as a small set of stable 64-bit keys, one per line in
/// hex, at $XDG_CONFIG_HOME/zehn/favorites (falling back to ~/.config). The key
/// is a hash of agent+text rather than the prompt itself: it keeps the file
/// tiny, avoids newline/encoding hazards from arbitrary prompt text, and stays
/// stable across runs even though the history files are read-only sources we
/// never write back to.
pub const Set = struct {
    map: std.AutoHashMap(u64, void),

    pub fn init(a: std.mem.Allocator) Set {
        return .{ .map = std.AutoHashMap(u64, void).init(a) };
    }

    pub fn deinit(self: *Set) void {
        self.map.deinit();
    }

    pub fn contains(self: *const Set, k: u64) bool {
        return self.map.contains(k);
    }

    pub fn count(self: *const Set) usize {
        return self.map.count();
    }

    /// Add the key if absent, remove it if present. Returns the new state
    /// (true = now a favorite). Allocation failure on insert is reported.
    pub fn toggle(self: *Set, k: u64) !bool {
        if (self.map.remove(k)) return false;
        try self.map.put(k, {});
        return true;
    }
};

/// Stable key for a prompt: hash of "<agent>\x00<text>". Same agent+text always
/// hashes the same, and two different agents with identical text differ — the
/// same distinction dedup() makes.
pub fn key(agent_label: []const u8, text: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(agent_label);
    h.update(&[_]u8{0});
    h.update(text);
    return h.final();
}

/// Combined ranking value: higher sorts first. Favorites form a strict tier
/// above non-favorites so a frequently-reused prompt surfaces ahead of an
/// incidental better-scoring match, while score still orders within each tier.
/// The shift is wide enough that no real match score can cross the tier line.
pub fn rank(score: i32, is_fav: bool) i64 {
    const tier: i64 = if (is_fav) 1 else 0;
    return (tier << 40) + score;
}

/// Parse the favorites file: one lowercase/uppercase hex u64 per line, blank
/// lines and anything unparseable ignored (forward-compatible / hand-edit safe).
pub fn parse(set: *Set, data: []const u8) !void {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        const k = std.fmt.parseInt(u64, t, 16) catch continue;
        try set.map.put(k, {});
    }
}

/// Serialize to the on-disk form: sorted hex keys, one per line, trailing
/// newline. Sorting makes the output deterministic (stable diffs, testable).
pub fn serialize(a: std.mem.Allocator, set: *const Set) ![]u8 {
    var keys = try a.alloc(u64, set.map.count());
    defer a.free(keys);
    var i: usize = 0;
    var it = set.map.keyIterator();
    while (it.next()) |k| : (i += 1) keys[i] = k.*;
    std.mem.sort(u64, keys, {}, std.sort.asc(u64));

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    for (keys) |k| try buf.print(a, "{x:0>16}\n", .{k});
    return buf.toOwnedSlice(a);
}

/// $XDG_CONFIG_HOME/zehn/favorites, or ~/.config/zehn/favorites.
pub fn pathFor(a: std.mem.Allocator, home: []const u8, xdg: ?[]const u8) ![]u8 {
    if (xdg) |x| if (x.len > 0) return std.fmt.allocPrint(a, "{s}/zehn/favorites", .{x});
    return std.fmt.allocPrint(a, "{s}/.config/zehn/favorites", .{home});
}

/// Load the favorites file into `set`. A missing file is fine (empty set).
pub fn load(set: *Set, io: Io, a: std.mem.Allocator, file_path: []const u8) void {
    const data = Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(8 * 1024 * 1024)) catch return;
    defer a.free(data);
    parse(set, data) catch {};
}

/// Persist `set` to `file_path`, creating the parent directory if needed.
/// Best-effort: a failure to save must never crash the picker.
pub fn save(set: *const Set, io: Io, a: std.mem.Allocator, file_path: []const u8) void {
    const bytes = serialize(a, set) catch return;
    defer a.free(bytes);
    if (std.fs.path.dirname(file_path)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = bytes }) catch {};
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "key is stable and distinguishes agent" {
    const a1 = key("claude", "fix the bug");
    try testing.expectEqual(a1, key("claude", "fix the bug"));
    try testing.expect(a1 != key("codex", "fix the bug"));
    try testing.expect(a1 != key("claude", "fix the bugs"));
}

test "toggle adds then removes" {
    var s = Set.init(testing.allocator);
    defer s.deinit();
    const k = key("pi", "hello");
    try testing.expect(!s.contains(k));
    try testing.expectEqual(true, try s.toggle(k));
    try testing.expect(s.contains(k));
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expectEqual(false, try s.toggle(k));
    try testing.expect(!s.contains(k));
    try testing.expectEqual(@as(usize, 0), s.count());
}

test "rank: favorites outrank non-favorites regardless of score" {
    // a favorite with a terrible score still beats a non-favorite perfect score
    try testing.expect(rank(-1000, true) > rank(2_000_000, false));
    // within a tier, higher score wins
    try testing.expect(rank(50, true) > rank(10, true));
    try testing.expect(rank(50, false) > rank(10, false));
}

test "parse ignores blanks and junk, round-trips with serialize" {
    var s = Set.init(testing.allocator);
    defer s.deinit();
    try parse(&s,
        \\00000000000000ff
        \\
        \\  not-hex-garbage
        \\0000000000000001
        \\00000000000000ff
    );
    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expect(s.contains(0xff));
    try testing.expect(s.contains(0x1));

    const out = try serialize(testing.allocator, &s);
    defer testing.allocator.free(out);
    // sorted, zero-padded, one per line
    try testing.expectEqualStrings("0000000000000001\n00000000000000ff\n", out);
}

test "serialize empty set is empty" {
    var s = Set.init(testing.allocator);
    defer s.deinit();
    const out = try serialize(testing.allocator, &s);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "pathFor honors XDG then falls back to ~/.config" {
    const a = testing.allocator;
    const p1 = try pathFor(a, "/home/x", "/cfg");
    defer a.free(p1);
    try testing.expectEqualStrings("/cfg/zehn/favorites", p1);
    const p2 = try pathFor(a, "/home/x", null);
    defer a.free(p2);
    try testing.expectEqualStrings("/home/x/.config/zehn/favorites", p2);
    const p3 = try pathFor(a, "/home/x", "");
    defer a.free(p3);
    try testing.expectEqualStrings("/home/x/.config/zehn/favorites", p3);
}
