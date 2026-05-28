const std = @import("std");

pub const Match = struct {
    score: i32,
    // up to 32 highlighted byte positions in the haystack
    positions: [32]u16 = undefined,
    pos_len: u8 = 0,
};

// fzf-style scoring constants.
const score_match: i32 = 16;
const gap_start: i32 = -3;
const gap_ext: i32 = -1;
const bonus_boundary: i32 = score_match / 2; // 8
const bonus_camel: i32 = bonus_boundary - 1; // 7
const bonus_consecutive: i32 = -(gap_start + gap_ext); // 4
const first_char_mult: i32 = 2;

const NEG: i32 = std.math.minInt(i32) / 2;

// Above this much DP work, fall back to the greedy scorer to stay fast on
// pathologically large haystacks.
const dp_budget: usize = 200_000;

const Class = enum(u3) { white, delim, nonword, lower, upper, number };

fn classOf(c: u8) Class {
    return switch (c) {
        ' ', '\t', '\n', '\r' => .white,
        '/', '\\', '_', '-', '.', ',', ':', ';', '(', ')', '[', ']', '{', '}' => .delim,
        '0'...'9' => .number,
        'a'...'z' => .lower,
        'A'...'Z' => .upper,
        else => .nonword,
    };
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqi(a: u8, b: u8) bool {
    return lower(a) == lower(b);
}

/// Bonus for a (word) haystack char given the preceding char's class.
fn bonusAt(prev: Class, cur: Class) i32 {
    if (cur == .white or cur == .delim or cur == .nonword) return 0;
    return switch (prev) {
        .white, .delim, .nonword => bonus_boundary,
        .lower => if (cur == .upper) bonus_camel else 0,
        .number => if (cur != .number) bonus_camel else 0,
        else => 0,
    };
}

/// Reusable matcher; holds scratch buffers so per-query matching avoids
/// repeated allocation.
pub const Matcher = struct {
    a: std.mem.Allocator,
    mm: []i32 = &.{}, // match-ending score matrix (m*n)
    par: []i32 = &.{}, // backtrack parent column (m*n)
    b: []i32 = &.{}, // per-column boundary bonus (n)
    r_best: []i32 = &.{}, // prefix-max of (mm[prev][c] - gap_ext*c) (n)
    r_arg: []i32 = &.{}, // argmax column for r_best (n)

    pub fn init(a: std.mem.Allocator) Matcher {
        return .{ .a = a };
    }

    fn ensure(self: *Matcher, cells: usize, win: usize) bool {
        if (self.mm.len < cells) {
            self.mm = self.a.realloc(self.mm, cells) catch return false;
            self.par = self.a.realloc(self.par, cells) catch return false;
        }
        if (self.b.len < win) {
            self.b = self.a.realloc(self.b, win) catch return false;
            self.r_best = self.a.realloc(self.r_best, win) catch return false;
            self.r_arg = self.a.realloc(self.r_arg, win) catch return false;
        }
        return true;
    }

    pub fn match(self: *Matcher, needle: []const u8, hay: []const u8) ?Match {
        if (needle.len == 0) return Match{ .score = 0 };
        if (hay.len == 0) return null;

        // Window = first occurrence of needle[0] .. last occurrence of the
        // final needle char. Anything outside cannot be part of a match.
        var sidx: usize = hay.len;
        for (hay, 0..) |hc, i| {
            if (eqi(hc, needle[0])) {
                sidx = i;
                break;
            }
        }
        if (sidx == hay.len) return null;

        const last = needle[needle.len - 1];
        var eidx: usize = 0;
        var i: usize = hay.len;
        while (i > sidx) : (i -= 1) {
            if (eqi(hay[i - 1], last)) {
                eidx = i;
                break;
            }
        }
        if (eidx <= sidx) return null;

        const win = hay[sidx..eidx];
        const m = needle.len;
        const n = win.len;
        if (n < m) return null;

        if (m * n > dp_budget) return greedy(needle, hay, sidx);
        if (!self.ensure(m * n, n)) return greedy(needle, hay, sidx);

        return self.dp(needle, hay, win, sidx);
    }

    // Affine-gap optimal alignment. mm[i][j] = best score for aligning
    // needle[0..i] with needle[i] matched exactly at window column j.
    fn dp(self: *Matcher, needle: []const u8, hay: []const u8, win: []const u8, base: usize) ?Match {
        const m = needle.len;
        const n = win.len;
        const mm = self.mm;
        const par = self.par;
        const B = self.b;

        for (0..n) |j| {
            const prev_char: u8 = if (base + j == 0) ' ' else hay[base + j - 1];
            B[j] = bonusAt(classOf(prev_char), classOf(win[j]));
        }

        // row 0: first needle char, with leading-skip penalty j*gap_ext
        for (0..n) |j| {
            const idx = j;
            if (eqi(win[j], needle[0])) {
                mm[idx] = score_match + B[j] * first_char_mult + @as(i32, @intCast(j)) * gap_ext;
                par[idx] = -1;
            } else {
                mm[idx] = NEG;
                par[idx] = -1;
            }
        }

        for (1..m) |i| {
            const row = i * n;
            const prow = (i - 1) * n;

            // prefix-max R[x] = max_{c<=x} (mm[prow+c] - gap_ext*c), with argmax
            var run_best: i32 = NEG;
            var run_arg: i32 = -1;
            for (0..n) |c| {
                const v = mm[prow + c];
                if (v > NEG) {
                    const adj = v - @as(i32, @intCast(c)) * gap_ext;
                    if (adj > run_best) {
                        run_best = adj;
                        run_arg = @intCast(c);
                    }
                }
                self.r_best[c] = run_best;
                self.r_arg[c] = run_arg;
            }

            for (0..n) |j| {
                const idx = row + j;
                if (!eqi(win[j], needle[i])) {
                    mm[idx] = NEG;
                    par[idx] = -1;
                    continue;
                }
                // consecutive: predecessor matched at j-1
                var v_con: i32 = NEG;
                if (j >= 1 and mm[prow + j - 1] > NEG) {
                    v_con = mm[prow + j - 1] + score_match + @max(B[j], bonus_consecutive);
                }
                // gap: predecessor matched at c <= j-2
                var v_non: i32 = NEG;
                var non_par: i32 = -1;
                if (j >= 2 and self.r_best[j - 2] > NEG) {
                    const pred = gap_start + @as(i32, @intCast(j - 2)) * gap_ext + self.r_best[j - 2];
                    v_non = pred + score_match + B[j];
                    non_par = self.r_arg[j - 2];
                }
                if (v_con >= v_non) {
                    mm[idx] = v_con;
                    par[idx] = if (v_con > NEG) @intCast(j - 1) else -1;
                } else {
                    mm[idx] = v_non;
                    par[idx] = non_par;
                }
            }
        }

        // best end cell in last row
        var best: i32 = NEG;
        var best_j: usize = 0;
        const last_row = (m - 1) * n;
        for (0..n) |j| {
            if (mm[last_row + j] > best) {
                best = mm[last_row + j];
                best_j = j;
            }
        }
        if (best <= NEG) return null;

        var result = Match{ .score = best };
        var tmp: [64]u16 = undefined;
        var cnt: usize = 0;
        var i: i32 = @intCast(m - 1);
        var j: i32 = @intCast(best_j);
        while (i >= 0 and j >= 0) {
            if (cnt < tmp.len) {
                tmp[cnt] = @intCast(base + @as(usize, @intCast(j)));
                cnt += 1;
            }
            const p = par[@as(usize, @intCast(i)) * n + @as(usize, @intCast(j))];
            i -= 1;
            j = p;
        }
        var k: usize = 0;
        while (k < cnt and k < result.positions.len) : (k += 1) {
            result.positions[k] = tmp[cnt - 1 - k];
        }
        result.pos_len = @intCast(@min(cnt, result.positions.len));
        return result;
    }
};

/// Greedy fallback for oversized haystacks. Agrees with the DP on *whether*
/// a match exists; score/positions may be suboptimal.
fn greedy(needle: []const u8, hay: []const u8, start: usize) ?Match {
    var m = Match{ .score = 0 };
    var ni: usize = 0;
    var consecutive: i32 = 0;
    var prev: Class = .white;
    var hi: usize = start;
    while (hi < hay.len and ni < needle.len) : (hi += 1) {
        const hc = hay[hi];
        if (eqi(hc, needle[ni])) {
            var s: i32 = score_match;
            s += bonusAt(prev, classOf(hc));
            if (consecutive > 0) s += bonus_consecutive;
            m.score += s;
            consecutive += 1;
            if (m.pos_len < m.positions.len) {
                m.positions[m.pos_len] = @intCast(hi);
                m.pos_len += 1;
            }
            ni += 1;
        } else {
            consecutive = 0;
        }
        prev = classOf(hc);
    }
    if (ni < needle.len) return null;
    return m;
}

/// Convenience wrapper for one-off matching (allocates scratch each call).
pub fn match(needle: []const u8, hay: []const u8) ?Match {
    var m = Matcher.init(std.heap.page_allocator);
    return m.match(needle, hay);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "empty needle matches with score 0" {
    const r = match("", "anything").?;
    try testing.expectEqual(@as(i32, 0), r.score);
}

test "non-subsequence returns null" {
    try testing.expect(match("xyz", "abcdef") == null);
    try testing.expect(match("abcd", "abc") == null);
}

test "case-insensitive match" {
    try testing.expect(match("ABC", "xxabcxx") != null);
    try testing.expect(match("abc", "XXABCXX") != null);
}

test "boundary-rich scattered match outscores a buried consecutive run" {
    // Each of a,b,c starts a word -> three boundary bonuses, which (correctly,
    // like fzf) beats one boundary + two consecutive bonuses in "abc".
    const r = match("abc", "a b c xxabc").?;
    const p = r.positions[0..r.pos_len];
    try testing.expectEqual(@as(u16, 0), p[0]);
    try testing.expectEqual(@as(u16, 2), p[1]);
    try testing.expectEqual(@as(u16, 4), p[2]);
}

// Reference scorer mirroring the DP cost model for one explicit alignment.
fn scoreAlignment(hay: []const u8, sidx: usize, pos: []const usize) i32 {
    var total: i32 = 0;
    for (pos, 0..) |p, k| {
        const prev_char: u8 = if (p == 0) ' ' else hay[p - 1];
        var b = bonusAt(classOf(prev_char), classOf(hay[p]));
        total += score_match;
        if (k == 0) {
            total += @as(i32, @intCast(p - sidx)) * gap_ext; // leading skip
            total += b * first_char_mult;
        } else {
            const gap = p - pos[k - 1] - 1;
            if (gap == 0) {
                b = @max(b, bonus_consecutive);
            } else {
                total += gap_start + gap_ext * @as(i32, @intCast(gap - 1));
            }
            total += b;
        }
    }
    return total;
}

fn bruteBest(needle: []const u8, hay: []const u8) ?i32 {
    var sidx: usize = hay.len;
    for (hay, 0..) |c, i| {
        if (eqi(c, needle[0])) {
            sidx = i;
            break;
        }
    }
    if (sidx == hay.len) return null;

    var pos: [8]usize = undefined;
    var best: ?i32 = null;
    bruteRec(needle, hay, sidx, &pos, 0, sidx, &best);
    return best;
}

fn bruteRec(needle: []const u8, hay: []const u8, sidx: usize, pos: []usize, k: usize, from: usize, best: *?i32) void {
    if (k == needle.len) {
        const s = scoreAlignment(hay, sidx, pos[0..needle.len]);
        if (best.* == null or s > best.*.?) best.* = s;
        return;
    }
    var i: usize = from;
    while (i < hay.len) : (i += 1) {
        if (eqi(hay[i], needle[k])) {
            pos[k] = i;
            bruteRec(needle, hay, sidx, pos, k + 1, i + 1, best);
        }
    }
}

test "optimality: DP equals brute-force optimum on random small inputs" {
    var prng = std.Random.DefaultPrng.init(0x7e40_1234_5678_9abc);
    const rnd = prng.random();
    const alphabet = "abc-_ ";
    var hbuf: [16]u8 = undefined;
    var nbuf: [4]u8 = undefined;
    var trials: usize = 0;
    var matched: usize = 0;
    while (trials < 6000) : (trials += 1) {
        const hl = rnd.intRangeAtMost(usize, 1, hbuf.len);
        for (hbuf[0..hl]) |*ch| ch.* = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
        const nl = rnd.intRangeAtMost(usize, 1, nbuf.len);
        for (nbuf[0..nl]) |*ch| ch.* = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
        const hay = hbuf[0..hl];
        const ndl = nbuf[0..nl];

        const dp_res = match(ndl, hay);
        const brute = bruteBest(ndl, hay);
        try testing.expectEqual(brute == null, dp_res == null);
        if (dp_res) |d| {
            matched += 1;
            try testing.expectEqual(brute.?, d.score);
        }
    }
    try testing.expect(matched > 1000); // sanity: we actually exercised matches
}

test "word-boundary beats mid-word match in score" {
    const boundary = match("run", "run tests").?;
    const midword = match("run", "babylonrun").?;
    try testing.expect(boundary.score > midword.score);
}

test "consecutive scores higher than gapped" {
    const consec = match("ab", "xabx").?;
    const gapped = match("ab", "xaxbx").?;
    try testing.expect(consec.score > gapped.score);
}

test "positions are ascending and correct" {
    const r = match("zhn", "zehn finder").?;
    const p = r.positions[0..r.pos_len];
    try testing.expectEqual(@as(usize, 3), p.len);
    try testing.expectEqual(@as(u16, 0), p[0]); // z
    try testing.expectEqual(@as(u16, 2), p[1]); // h
    try testing.expectEqual(@as(u16, 3), p[2]); // n
}

test "matcher reuse across queries" {
    var mt = Matcher.init(testing.allocator);
    defer {
        if (mt.mm.len > 0) testing.allocator.free(mt.mm);
        if (mt.par.len > 0) testing.allocator.free(mt.par);
        if (mt.b.len > 0) testing.allocator.free(mt.b);
        if (mt.r_best.len > 0) testing.allocator.free(mt.r_best);
        if (mt.r_arg.len > 0) testing.allocator.free(mt.r_arg);
    }
    try testing.expect(mt.match("foo", "foobar") != null);
    try testing.expect(mt.match("bar", "foobar") != null);
    try testing.expect(mt.match("zzz", "foobar") == null);
}
