//! Anthropic streaming-protocol interpretation.

const std = @import("std");
const sse = @import("../sse.zig");

const MessageDelta = struct {
    const Delta = struct {
        stop_reason: ?[]const u8 = null,
    };

    type: ?[]const u8 = null,
    delta: ?Delta = null,
};

/// Returns whether an SSE event explicitly reports a naturally completed
/// Claude turn.
///
/// The event name, JSON type, and stop reason must agree. Malformed,
/// incomplete, or truncated input is treated as absent evidence.
///
/// ```zig
/// const completed = completesTurn(.{
///     .name = "message_delta",
///     .data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
///     .truncated = false,
/// });
/// ```
pub fn completesTurn(event: sse.Event) bool {
    if (event.truncated or !std.mem.eql(u8, event.name, "message_delta")) {
        return false;
    }

    var storage: [sse.max_data_bytes]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    const message = std.json.parseFromSliceLeaky(MessageDelta, allocator.allocator(), event.data, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    const delta = message.delta orelse return false;

    return std.mem.eql(u8, message.type orelse return false, "message_delta") and
        std.mem.eql(u8, delta.stop_reason orelse return false, "end_turn");
}

fn testEvent(name: []const u8, data: []const u8) sse.Event {
    return .{ .name = name, .data = data, .truncated = false };
}

test "Claude end_turn requires matching SSE and JSON event types" {
    const payload = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}";

    try std.testing.expect(completesTurn(testEvent("message_delta", payload)));
    try std.testing.expect(!completesTurn(testEvent("message_stop", payload)));
    try std.testing.expect(!completesTurn(testEvent(
        "message_delta",
        "{\"type\":\"message_stop\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
    )));
}

test "Claude end_turn accepts field reordering unknown fields and escaped text" {
    try std.testing.expect(completesTurn(testEvent(
        "message_delta",
        "{\"extra\":true,\"delta\":{\"extra\":1,\"stop_reason\":\"end\\u005fturn\"},\"type\":\"message_delta\"}",
    )));
}

test "Claude nonterminal and continuation stop reasons do not complete a turn" {
    inline for (.{ "tool_use", "max_tokens", "stop_sequence", "pause_turn", "refusal" }) |reason| {
        var buffer: [160]u8 = undefined;
        const payload = try std.fmt.bufPrint(
            &buffer,
            "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}}}}",
            .{reason},
        );

        try std.testing.expect(!completesTurn(testEvent("message_delta", payload)));
    }
}

test "Claude completion rejects missing null malformed and misleading fields" {
    const cases = [_][]const u8{
        "{}",
        "{\"type\":\"message_delta\"}",
        "{\"type\":\"message_delta\",\"delta\":{}}",
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null}}",
        "{\"type\":\"message_delta\",\"delta\":null}",
        "{\"type\":\"message_delta\",\"delta\":{\"text\":\"\\\"stop_reason\\\":\\\"end_turn\\\"\"}}",
        "{\"type\":\"message_delta\",\"other\":{\"stop_reason\":\"end_turn\"},\"delta\":{}}",
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}",
        "not json",
    };

    for (cases) |payload| {
        try std.testing.expect(!completesTurn(testEvent("message_delta", payload)));
    }
}

test "Claude completion rejects an SSE event whose retained data was truncated" {
    var candidate = testEvent(
        "message_delta",
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
    );
    candidate.truncated = true;

    try std.testing.expect(!completesTurn(candidate));
}
