//! "Forking" a prompt means reusing its text somewhere other than its origin
//! session: copy it to the clipboard, or start a *fresh* session with it in any
//! agent (including a different one than it came from). These builders are pure
//! so the argv decisions are unit-testable; the actual spawning lives in main.

const std = @import("std");
const builtin = @import("builtin");
const scan = @import("scan.zig");

/// Clipboard copy commands to try in order. Different platforms (and Linux
/// display servers) ship different tools, so we attempt each until one works.
/// The prompt text is fed on stdin, never as an argv element, so even huge or
/// shell-special prompts are safe.
pub fn clipboardCandidates() []const []const []const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{
            &.{"pbcopy"},
        },
        else => &.{
            &.{"wl-copy"}, // wayland
            &.{ "xclip", "-selection", "clipboard" }, // x11
            &.{ "xsel", "--clipboard", "--input" }, // x11 alt
        },
    };
}

/// Argv to start a brand-new session in `agent` seeded with `prompt` as the
/// first message. Unlike resume (main.zig), this does not need a session id —
/// it's a fresh conversation, so the same prompt can be branched into any agent.
pub fn freshSessionArgv(agent: scan.Agent, prompt: []const u8) [2][]const u8 {
    return switch (agent) {
        .claude => .{ "claude", prompt },
        .codex => .{ "codex", prompt },
        .pi => .{ "pi", prompt },
        .opencode => .{ "opencode", prompt },
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "clipboard candidates are non-empty and platform-shaped" {
    const c = clipboardCandidates();
    try testing.expect(c.len >= 1);
    for (c) |cmd| try testing.expect(cmd.len >= 1);
    switch (builtin.os.tag) {
        .macos => try testing.expectEqualStrings("pbcopy", c[0][0]),
        else => try testing.expectEqualStrings("wl-copy", c[0][0]),
    }
}

test "freshSessionArgv carries the prompt as a single arg per agent" {
    inline for (.{
        .{ scan.Agent.claude, "claude" },
        .{ scan.Agent.codex, "codex" },
        .{ scan.Agent.pi, "pi" },
        .{ scan.Agent.opencode, "opencode" },
    }) |c| {
        const argv = freshSessionArgv(c[0], "make it faster");
        try testing.expectEqualStrings(c[1], argv[0]);
        try testing.expectEqualStrings("make it faster", argv[1]);
    }
}
