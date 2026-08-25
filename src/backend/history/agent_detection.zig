//! Bounded terminal-output heuristics for Codex and Claude Code.
//!
//! These patterns are presentation hints only. They may mark a pane as busy or
//! visibly blocked; they never grant permission or generate input.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const Status = enum { working, blocked, ready };

pub const Signal = struct {
    provider: schema.AgentProvider = .unknown,
    status: Status,
    confidence: u8,
    identity_confirmed: bool = false,
};

/// A sample spans one sealed observation batch, so a prompt which disappeared
/// cannot remain authoritative in a long-lived byte ring.
pub const Detector = struct {
    pub const capacity = 16 * 1024;

    bytes: [capacity]u8 = undefined,
    len: usize = 0,
    state: enum { text, escape, csi, osc, osc_escape, string, string_escape } = .text,

    pub fn resetSample(detector: *Detector) void {
        detector.len = 0;
    }

    pub fn observe(detector: *Detector, input: []const u8) void {
        for (input) |byte| detector.observeByte(byte);
    }

    pub fn signal(detector: *const Detector) ?Signal {
        const text = detector.bytes[0..detector.len];
        if (containsAnyAscii(text, &.{
            "press enter to confirm",
            "enter to submit answer",
            "enter to select",
            "allow command?",
            "[y/n]",
            "do you want to proceed?",
            "waiting for permission",
            "yes, and don't ask again",
        })) return .{ .provider = inferProvider(text), .status = .blocked, .confidence = 88 };

        if (containsAnyAscii(text, &.{
            "esc to interrupt",
            "working (",
            "waiting for background agents",
            "tasks still running",
            "background shells",
        })) return .{ .provider = inferProvider(text), .status = .working, .confidence = 78 };

        if (containsAsciiInsensitive(text, "ask codex to do anything"))
            return .{
                .provider = .codex,
                .status = .ready,
                .confidence = 94,
                .identity_confirmed = true,
            };

        // Claude's branded header and prompt often arrive in different sealed
        // observation batches. The header establishes identity on its own;
        // later generic prompts may then refresh the existing agent record.
        if (containsAsciiInsensitive(text, "claude code"))
            return .{
                .provider = .claude,
                .status = .ready,
                .confidence = 90,
                .identity_confirmed = true,
            };

        if (std.mem.indexOf(u8, text, "\xe2\x9d\xaf") != null) return .{
            .provider = .claude,
            .status = .ready,
            .confidence = 72,
        };
        return null;
    }

    fn observeByte(detector: *Detector, byte: u8) void {
        switch (detector.state) {
            .text => switch (byte) {
                0x1b => detector.state = .escape,
                '\r', '\n', '\t' => detector.append(' '),
                else => if (byte >= 0x20 and byte != 0x7f) detector.append(byte),
            },
            .escape => switch (byte) {
                '[' => detector.state = .csi,
                ']' => detector.state = .osc,
                'P', '_', '^' => detector.state = .string,
                else => detector.state = .text,
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) detector.state = .text;
            },
            .osc => switch (byte) {
                0x07 => detector.state = .text,
                0x1b => detector.state = .osc_escape,
                else => {},
            },
            .osc_escape => detector.state = if (byte == '\\') .text else .osc,
            .string => {
                if (byte == 0x1b) detector.state = .string_escape;
            },
            .string_escape => detector.state = if (byte == '\\') .text else .string,
        }
    }

    fn append(detector: *Detector, byte: u8) void {
        if (detector.len == detector.bytes.len) {
            const keep = detector.bytes.len / 2;
            std.mem.copyForwards(
                u8,
                detector.bytes[0..keep],
                detector.bytes[detector.bytes.len - keep ..],
            );
            detector.len = keep;
        }
        detector.bytes[detector.len] = byte;
        detector.len += 1;
    }
};

fn inferProvider(text: []const u8) schema.AgentProvider {
    if (containsAsciiInsensitive(text, "claude")) return .claude;
    if (containsAsciiInsensitive(text, "codex")) return .codex;
    return .unknown;
}

fn containsAnyAscii(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (containsAsciiInsensitive(haystack, needle)) return true;
    return false;
}

fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |offset| {
        for (needle, 0..) |expected, index| {
            if (std.ascii.toLower(haystack[offset + index]) != std.ascii.toLower(expected)) break;
        } else return true;
    }
    return false;
}

test "strips terminal controls and recognizes permission prompts" {
    var detector: Detector = .{};
    detector.observe("\x1b[31mClaude\x1b[0m\r\nDo you want to proceed?  Enter to confirm");
    const detected = detector.signal().?;
    try std.testing.expectEqual(Status.blocked, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, detected.provider);
}

test "recognizes codex work split across output bursts" {
    var detector: Detector = .{};
    detector.observe("Cod");
    detector.observe("ex  Work");
    detector.observe("ing (12s, esc to interrupt)");
    const detected = detector.signal().?;
    try std.testing.expectEqual(Status.working, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
}

test "recognizes an open Codex prompt without proxy evidence" {
    var detector: Detector = .{};
    detector.observe("OpenAI Codex  Ask Codex to do anything");
    const detected = detector.signal().?;
    try std.testing.expectEqual(Status.ready, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
    try std.testing.expect(detected.identity_confirmed);
}

test "Claude branding and prompt may arrive in separate samples" {
    var detector: Detector = .{};
    detector.observe("\x1b[1mClaude Code\x1b[0m v2.1");
    const branded = detector.signal().?;
    try std.testing.expectEqual(Status.ready, branded.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, branded.provider);
    try std.testing.expect(branded.identity_confirmed);

    detector.resetSample();
    detector.observe("\xe2\x9d\xaf");
    const prompt = detector.signal().?;
    try std.testing.expectEqual(Status.ready, prompt.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, prompt.provider);
    try std.testing.expect(!prompt.identity_confirmed);
}

test "terminal controls may split at every byte" {
    const input = "\x1b]2;private title\x1b\\\x1b[31mClaude\x1b[0m Do you want to proceed?";
    for (0..input.len + 1) |split| {
        var detector: Detector = .{};
        detector.observe(input[0..split]);
        detector.observe(input[split..]);
        const detected = detector.signal().?;
        try std.testing.expectEqual(Status.blocked, detected.status);
        try std.testing.expectEqual(schema.AgentProvider.claude, detected.provider);
    }
}
