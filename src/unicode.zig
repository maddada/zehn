const std = @import("std");

/// Number of bytes in the UTF-8 sequence starting at `first`. Returns 1 for
/// invalid lead bytes so callers always make progress.
pub fn seqLen(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

/// Decode the codepoint at the start of `s`; returns the codepoint and the
/// number of bytes consumed. Invalid sequences decode as U+FFFD over 1 byte.
pub fn decode(s: []const u8) struct { cp: u21, len: usize } {
    if (s.len == 0) return .{ .cp = 0, .len = 0 };
    const n = seqLen(s[0]);
    if (n == 1 or n > s.len) return .{ .cp = s[0], .len = 1 };
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Terminal display width of a codepoint: 0 (combining/zero-width),
/// 1 (normal), or 2 (wide CJK / most emoji). Compact wcwidth approximation.
pub fn charWidth(cp: u21) u8 {
    if (cp == 0) return 0;
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0; // control
    // combining marks / zero-width
    if ((cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or
        cp == 0x200b or cp == 0x200c or cp == 0x200d or cp == 0xfeff)
        return 0;
    // wide ranges
    if ((cp >= 0x1100 and cp <= 0x115f) or // Hangul Jamo
        (cp >= 0x2e80 and cp <= 0x303e) or // CJK radicals/symbols
        (cp >= 0x3041 and cp <= 0x33ff) or // Hiragana..CJK compat
        (cp >= 0x3400 and cp <= 0x4dbf) or // CJK ext A
        (cp >= 0x4e00 and cp <= 0x9fff) or // CJK unified
        (cp >= 0xa000 and cp <= 0xa4cf) or // Yi
        (cp >= 0xac00 and cp <= 0xd7a3) or // Hangul syllables
        (cp >= 0xf900 and cp <= 0xfaff) or // CJK compat ideographs
        (cp >= 0xfe30 and cp <= 0xfe4f) or // CJK compat forms
        (cp >= 0xff00 and cp <= 0xff60) or // fullwidth forms
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1faff) or // emoji & symbols
        (cp >= 0x20000 and cp <= 0x3fffd)) // CJK ext B+
        return 2;
    return 1;
}

/// Display width of an entire UTF-8 string.
pub fn width(s: []const u8) usize {
    var i: usize = 0;
    var w: usize = 0;
    while (i < s.len) {
        const d = decode(s[i..]);
        w += charWidth(d.cp);
        i += d.len;
    }
    return w;
}
