//! Provider-specific interpretation of streamed model responses.
//!
//! Transport parsers feed response payload bytes here. This module owns SSE
//! framing and provider semantics, but it does not publish lifecycle events or
//! know which agent owns the exchange.

const types = @import("../../agent/types.zig");
const request = @import("request_support.zig");
const dialect_mod = @import("dialect.zig");
const claude_transport = @import("claude_transport.zig");
const ResponseObserverType = @import("ResponseObserver.zig");
const ResponseStreamsType = @import("ResponseStreams.zig");
const std = @import("std");
const sse = @import("../sse.zig");
const claude = @import("claude.zig");

pub const ApiDialect = types.ApiDialect;

pub const Request = @import("Request.zig");
pub const RequestClass = request.RequestClass;
pub const identify = dialect_mod.identify;
pub const classify = request.classify;
pub const RequestObserver = @import("Observer.zig");
pub const RequestFragment = @import("Fragment.zig");
pub const RequestStreams = @import("Streams.zig");
pub const claudeRequestTransformer = claude_transport.requestTransformer;

pub const max_concurrent_responses = 128;

pub const ResponseObserver = @import("ResponseObserver.zig");

pub const ResponseStreams = @import("ResponseStreams.zig");

const end_turn_event =
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n" ++
    "\n";

test "response observer reports Claude completion exactly once" {
    var observer = ResponseObserverType.init(.anthropic_messages);
    defer observer.deinit();

    try std.testing.expect(observer.feed(end_turn_event));
    try std.testing.expect(!observer.feed(end_turn_event));
    try std.testing.expect(!observer.feed("event: message_stop\ndata: {}\n\n"));
}

test "response observer preserves Claude SSE state across every split" {
    for (0..end_turn_event.len + 1) |split| {
        var observer = ResponseObserverType.init(.anthropic_messages);
        defer observer.deinit();

        const completed_before_second_chunk = observer.feed(end_turn_event[0..split]);
        const completed_by_second_chunk = observer.feed(end_turn_event[split..]);

        try std.testing.expectEqual(split == end_turn_event.len, completed_before_second_chunk);
        try std.testing.expectEqual(split != end_turn_event.len, completed_by_second_chunk);
    }
}

test "response observer ignores stream closure and tool continuation" {
    var observer = ResponseObserverType.init(.anthropic_messages);
    defer observer.deinit();

    try std.testing.expect(!observer.feed(
        "event: message_delta\n" ++
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n",
    ));
    try std.testing.expect(!observer.feed("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"));
}

test "response observer ignores malformed and truncated SSE input" {
    var observer = ResponseObserverType.init(.anthropic_messages);
    defer observer.deinit();

    try std.testing.expect(!observer.feed("event: message_delta\ndata: not-json\n\n"));

    const oversized = "event: message_delta\ndata: " ++
        ("x" ** (sse.max_data_bytes + 1)) ++ "\n\n";
    try std.testing.expect(!observer.feed(oversized));
}

test "response observer ignores unsupported providers" {
    inline for (.{ types.ApiDialect.unknown, types.ApiDialect.openai_responses }) |dialect| {
        var observer = ResponseObserverType.init(dialect);
        defer observer.deinit();

        try std.testing.expect(!observer.feed(end_turn_event));
    }
}

test "response streams decode arbitrarily interleaved HTTP2 payloads independently" {
    const first_split = end_turn_event.len / 3;
    const second_split = 2 * end_turn_event.len / 3;
    var streams = ResponseStreamsType.init(std.testing.allocator, .anthropic_messages);
    defer streams.deinit();

    try std.testing.expect(!streams.feed(1, end_turn_event[0..first_split]));
    try std.testing.expect(!streams.feed(3, end_turn_event[0..second_split]));
    try std.testing.expect(!streams.feed(1, end_turn_event[first_split..second_split]));
    try std.testing.expect(streams.feed(3, end_turn_event[second_split..]));
    try std.testing.expect(streams.feed(1, end_turn_event[second_split..]));
    try std.testing.expect(!streams.feed(1, end_turn_event));
    try std.testing.expect(!streams.feed(3, end_turn_event));
}

test "response streams discard finished state and allow stream-slot reuse" {
    var streams = ResponseStreamsType.init(std.testing.allocator, .anthropic_messages);
    defer streams.deinit();

    try std.testing.expect(!streams.feed(7, end_turn_event[0 .. end_turn_event.len / 2]));
    streams.finish(7);
    try std.testing.expect(!streams.feed(7, end_turn_event[end_turn_event.len / 2 ..]));
    streams.finish(7);
    try std.testing.expect(streams.feed(7, end_turn_event));
}

test "response streams reject the connection sentinel and unsupported providers" {
    var claude_streams = ResponseStreamsType.init(std.testing.allocator, .anthropic_messages);
    defer claude_streams.deinit();
    try std.testing.expect(!claude_streams.feed(0, end_turn_event));

    var codex_streams = ResponseStreamsType.init(std.testing.allocator, .openai_responses);
    defer codex_streams.deinit();
    try std.testing.expect(!codex_streams.feed(1, end_turn_event));
}

test "response stream allocation failure drops observation without retaining a slot" {
    var storage: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var streams = ResponseStreamsType.init(allocator.allocator(), .anthropic_messages);
    defer streams.deinit();

    try std.testing.expect(!streams.feed(1, end_turn_event));
    try std.testing.expect(streams.find(1) == null);
}

test "response streams degrade locally at their fixed concurrency bound" {
    var streams = ResponseStreamsType.init(std.testing.allocator, .anthropic_messages);
    defer streams.deinit();

    for (0..max_concurrent_responses) |index| {
        try std.testing.expect(!streams.feed(@intCast(2 * index + 1), "event: message_delta\n"));
    }

    const overflow_stream: u32 = 2 * max_concurrent_responses + 1;
    try std.testing.expect(!streams.feed(overflow_stream, end_turn_event));

    streams.finish(1);
    try std.testing.expect(streams.feed(overflow_stream, end_turn_event));
}

test {
    std.testing.refAllDecls(claude);
    std.testing.refAllDecls(dialect_mod);
    std.testing.refAllDecls(request);
}
