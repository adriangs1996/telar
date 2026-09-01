//! Bounded terminal-output sampling for agent screen heuristics.
//!
//! These patterns are presentation hints only. They may mark a pane as busy or
//! visibly blocked; they never grant permission or generate input.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const Status = core.agent_manifest.Status;
pub const Signal = core.agent_manifest.Signal;
pub const Table = core.agent_manifest.Table;

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

    /// Applies the manifest table's heuristics to the plain-text sample.
    ///
    /// ```zig
    /// const signal = detector.signal(&core.agent_manifest.builtin_table);
    /// ```
    pub fn signal(detector: *const Detector, table: *const Table) ?Signal {
        return table.detect(detector.bytes[0..detector.len]);
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

test "strips terminal controls and recognizes permission prompts" {
    var detector: Detector = .{};
    detector.observe("\x1b[31mClaude\x1b[0m\r\nDo you want to proceed?  Enter to confirm");
    const detected = detector.signal(&core.agent_manifest.builtin_table).?;
    try std.testing.expectEqual(Status.blocked, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, detected.provider);
}

test "recognizes codex work split across output bursts" {
    var detector: Detector = .{};
    detector.observe("Cod");
    detector.observe("ex  Work");
    detector.observe("ing (12s, esc to interrupt)");
    const detected = detector.signal(&core.agent_manifest.builtin_table).?;
    try std.testing.expectEqual(Status.working, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
}

test "recognizes an open Codex prompt without proxy evidence" {
    var detector: Detector = .{};
    detector.observe("OpenAI Codex  Ask Codex to do anything");
    const detected = detector.signal(&core.agent_manifest.builtin_table).?;
    try std.testing.expectEqual(Status.ready, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
    try std.testing.expect(detected.identity_confirmed);
    try std.testing.expect(detected.ready_confirmed);
}

test "Claude branding confirms identity without claiming a prompt" {
    var detector: Detector = .{};
    detector.observe("\x1b[1mClaude Code\x1b[0m v2.1");
    const branded = detector.signal(&core.agent_manifest.builtin_table).?;
    try std.testing.expectEqual(Status.ready, branded.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, branded.provider);
    try std.testing.expect(branded.identity_confirmed);
    try std.testing.expect(!branded.ready_confirmed);

    detector.resetSample();
    detector.observe("\xe2\x9d\xaf");
    try std.testing.expect(detector.signal(&core.agent_manifest.builtin_table) == null);
}

test "terminal controls may split at every byte" {
    const input = "\x1b]2;private title\x1b\\\x1b[31mClaude\x1b[0m Do you want to proceed?";
    for (0..input.len + 1) |split| {
        var detector: Detector = .{};
        detector.observe(input[0..split]);
        detector.observe(input[split..]);
        const detected = detector.signal(&core.agent_manifest.builtin_table).?;
        try std.testing.expectEqual(Status.blocked, detected.status);
        try std.testing.expectEqual(schema.AgentProvider.claude, detected.provider);
    }
}
