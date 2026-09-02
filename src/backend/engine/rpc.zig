//! JSONL codec for Pi's RPC mode. It encodes the two commands the engine
//! sends and recognizes the few records the engine acts on; every other
//! event on the stream is skipped without inspection.
//!
//! Pi frames records with a bare LF and may emit an optional trailing CR.
//! Records are JSON objects with a `type`; command replies carry
//! `type = "response"`, the echoed `command` and a `success` flag.

const std = @import("std");

/// Longest record the engine parses. Longer records are discarded whole; a
/// discarded reply surfaces as `invalid_output` rather than a timeout.
pub const max_line_bytes = 64 * 1024;

pub const Kind = enum {
    prompt_accepted,
    prompt_rejected,
    agent_settled,
    last_text,
    other,
};

const Envelope = struct {
    type: []const u8 = "",
    command: []const u8 = "",
    success: ?bool = null,
    data: ?Data = null,

    const Data = struct {
        text: ?[]const u8 = null,
    };
};

/// One parsed record. `text` borrows the parse arena, so copy it before
/// `deinit`.
pub const Record = struct {
    parsed: std.json.Parsed(Envelope),
    kind: Kind,

    /// The assistant text of a `get_last_assistant_text` reply, or null when
    /// the session holds no assistant message.
    ///
    /// ```zig
    /// const text = record.text() orelse return;
    /// ```
    pub fn text(record: *const Record) ?[]const u8 {
        const data = record.parsed.value.data orelse return null;
        return data.text;
    }

    pub fn deinit(record: *Record) void {
        record.parsed.deinit();
    }
};

/// Parses one record. Malformed JSON, arrays and records above the line
/// bound return null so a noisy stream never stalls the engine.
///
/// ```zig
/// var record = parse(gpa, line) orelse continue;
/// defer record.deinit();
/// ```
pub fn parse(gpa: std.mem.Allocator, line: []const u8) ?Record {
    if (line.len == 0 or line.len > max_line_bytes) {
        return null;
    }

    // Copy strings out of `line`: the caller's buffer moves on the next read.
    const parsed = std.json.parseFromSlice(Envelope, gpa, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    return .{ .parsed = parsed, .kind = classify(parsed.value) };
}

fn classify(envelope: Envelope) Kind {
    if (std.mem.eql(u8, envelope.type, "agent_settled")) {
        return .agent_settled;
    }

    if (!std.mem.eql(u8, envelope.type, "response")) {
        return .other;
    }

    if (std.mem.eql(u8, envelope.command, "prompt")) {
        return if (envelope.success == true) .prompt_accepted else .prompt_rejected;
    }

    if (std.mem.eql(u8, envelope.command, "get_last_assistant_text") and envelope.success == true) {
        return .last_text;
    }

    return .other;
}

/// Encodes a `prompt` command as one LF-terminated record.
///
/// ```zig
/// var buffer: [max_line_bytes]u8 = undefined;
/// const line = try encodePrompt(&buffer, "Summarize the diff");
/// ```
pub fn encodePrompt(buffer: []u8, message: []const u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{f}\n", .{std.json.fmt(.{ .type = "prompt", .message = message }, .{})});
    return writer.buffered();
}

/// Encodes a command without arguments as one LF-terminated record.
///
/// ```zig
/// const line = try encodeCommand(&buffer, "get_last_assistant_text");
/// ```
pub fn encodeCommand(buffer: []u8, command: []const u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{f}\n", .{std.json.fmt(.{ .type = command }, .{})});
    return writer.buffered();
}

test "prompt encoding escapes the message and ends the record with LF" {
    var buffer: [256]u8 = undefined;
    const line = try encodePrompt(&buffer, "say \"hi\"\nthen\u{2028}stop");
    try std.testing.expectEqualStrings(
        "{\"type\":\"prompt\",\"message\":\"say \\\"hi\\\"\\nthen\u{2028}stop\"}\n",
        line,
    );
    try std.testing.expectEqualStrings("{\"type\":\"get_last_assistant_text\"}\n", try encodeCommand(&buffer, "get_last_assistant_text"));

    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encodePrompt(&tiny, "too long for the buffer"));
}

test "records classify replies and settlement, and skip everything else" {
    const gpa = std.testing.allocator;

    var accepted = parse(gpa, "{\"id\":\"r1\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}").?;
    defer accepted.deinit();
    try std.testing.expectEqual(Kind.prompt_accepted, accepted.kind);

    var rejected = parse(gpa, "{\"type\":\"response\",\"command\":\"prompt\",\"success\":false,\"error\":\"busy\"}").?;
    defer rejected.deinit();
    try std.testing.expectEqual(Kind.prompt_rejected, rejected.kind);

    var settled = parse(gpa, "{\"type\":\"agent_settled\"}\r").?;
    defer settled.deinit();
    try std.testing.expectEqual(Kind.agent_settled, settled.kind);

    var last = parse(gpa, "{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":\"Improve sidebar\"}}").?;
    defer last.deinit();
    try std.testing.expectEqual(Kind.last_text, last.kind);
    try std.testing.expectEqualStrings("Improve sidebar", last.text().?);

    var empty = parse(gpa, "{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":null}}").?;
    defer empty.deinit();
    try std.testing.expectEqual(Kind.last_text, empty.kind);
    try std.testing.expect(empty.text() == null);

    var update = parse(gpa, "{\"type\":\"message_update\",\"message\":{\"role\":\"assistant\"},\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"x\"}}").?;
    defer update.deinit();
    try std.testing.expectEqual(Kind.other, update.kind);

    var state = parse(gpa, "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{\"model\":{\"id\":\"m\"},\"isStreaming\":false}}").?;
    defer state.deinit();
    try std.testing.expectEqual(Kind.other, state.kind);

    try std.testing.expect(parse(gpa, "") == null);
    try std.testing.expect(parse(gpa, "not json") == null);
    try std.testing.expect(parse(gpa, "[1,2,3]") == null);
}
