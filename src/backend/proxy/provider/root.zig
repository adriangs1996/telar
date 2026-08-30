//! Provider-specific interpretation of streamed model responses.
//!
//! Transport parsers feed response payload bytes here. This module owns SSE
//! framing and provider semantics, but it does not publish lifecycle events or
//! know which agent owns the exchange.

const std = @import("std");
const core = @import("telar-core");
const claude = @import("claude.zig");
const request = @import("request.zig");
const sse = @import("../sse.zig");

pub const AgentProvider = core.schema.AgentProvider;

pub const Request = request.Request;
pub const RequestClass = request.RequestClass;
pub const identify = request.identify;
pub const classify = request.classify;

pub const max_concurrent_responses = 128;

/// Bounded interpreter for one streamed provider response.
pub const ResponseObserver = struct {
    provider: AgentProvider = .unknown,
    decoder: sse.Decoder = .{},
    completed: bool = false,

    /// Starts observing one response from `provider`.
    ///
    /// ```zig
    /// var observer = ResponseObserver.init(.claude);
    /// defer observer.deinit();
    /// ```
    pub fn init(provider: AgentProvider) ResponseObserver {
        return .{ .provider = provider };
    }

    /// Consumes the next response payload fragment and returns `true` exactly
    /// once when it contains verified provider-turn completion.
    ///
    /// Fragments may split the SSE stream at any byte. Unsupported providers,
    /// malformed data, and later input after completion return `false`.
    ///
    /// ```zig
    /// const completed = observer.feed(
    ///     "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
    /// );
    /// ```
    pub fn feed(observer: *ResponseObserver, input: []const u8) bool {
        if (observer.completed or observer.provider != .claude) {
            return false;
        }

        const EventSink = struct {
            observer: *ResponseObserver,

            pub fn emit(sink: *@This(), event: sse.Event) void {
                sink.observer.inspectEvent(event);
            }
        };
        var sink: EventSink = .{ .observer = observer };
        observer.decoder.feed(input, &sink);
        return observer.completed;
    }

    /// Securely erases buffered provider response data.
    ///
    /// ```zig
    /// observer.deinit();
    /// ```
    pub fn deinit(observer: *ResponseObserver) void {
        std.crypto.secureZero(u8, std.mem.asBytes(observer));
    }

    fn inspectEvent(observer: *ResponseObserver, event: sse.Event) void {
        if (claude.completesTurn(event)) {
            observer.completed = true;
        }
    }
};

/// Bounded collection of response interpreters keyed by HTTP/2 stream ID.
pub const ResponseStreams = struct {
    const Slot = struct {
        stream_id: u32 = 0,
        response: ?*ResponseObserver = null,
    };

    allocator: std.mem.Allocator,
    provider: AgentProvider,
    slots: [max_concurrent_responses]Slot = @splat(.{}),

    /// Starts an empty set for one provider connection.
    ///
    /// ```zig
    /// var streams = ResponseStreams.init(allocator, .claude);
    /// defer streams.deinit();
    /// ```
    pub fn init(allocator: std.mem.Allocator, provider: AgentProvider) ResponseStreams {
        return .{ .allocator = allocator, .provider = provider };
    }

    /// Feeds one response payload fragment to its stream and reports a newly
    /// verified completion exactly once for that stream.
    ///
    /// A zero stream ID, unsupported provider, or capacity exhaustion drops
    /// only semantic observation; transport forwarding remains unaffected.
    ///
    /// ```zig
    /// if (streams.feed(stream_id, bytes)) publishCompletion(stream_id);
    /// ```
    pub fn feed(streams: *ResponseStreams, stream_id: u32, input: []const u8) bool {
        if (stream_id == 0 or streams.provider != .claude) {
            return false;
        }

        const slot = streams.find(stream_id) orelse streams.create(stream_id) orelse return false;
        return slot.response.?.feed(input);
    }

    /// Erases the parser state retained for a completed or failed stream.
    ///
    /// ```zig
    /// streams.finish(stream_id);
    /// ```
    pub fn finish(streams: *ResponseStreams, stream_id: u32) void {
        const slot = streams.find(stream_id) orelse return;
        const response = slot.response orelse return;
        response.deinit();
        streams.allocator.destroy(response);
        slot.* = .{};
    }

    /// Securely erases every retained stream fragment.
    ///
    /// ```zig
    /// streams.deinit();
    /// ```
    pub fn deinit(streams: *ResponseStreams) void {
        for (&streams.slots) |*slot| {
            const response = slot.response orelse continue;
            response.deinit();
            streams.allocator.destroy(response);
            slot.* = .{};
        }

        streams.provider = .unknown;
    }

    fn find(streams: *ResponseStreams, stream_id: u32) ?*Slot {
        for (&streams.slots) |*slot| {
            if (slot.stream_id == stream_id) {
                return slot;
            }
        }

        return null;
    }

    fn create(streams: *ResponseStreams, stream_id: u32) ?*Slot {
        for (&streams.slots) |*slot| {
            if (slot.stream_id != 0) {
                continue;
            }

            const response = streams.allocator.create(ResponseObserver) catch return null;
            response.* = .init(streams.provider);
            slot.* = .{
                .stream_id = stream_id,
                .response = response,
            };
            return slot;
        }

        return null;
    }
};

const end_turn_event =
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n" ++
    "\n";

test "response observer reports Claude completion exactly once" {
    var observer = ResponseObserver.init(.claude);
    defer observer.deinit();

    try std.testing.expect(observer.feed(end_turn_event));
    try std.testing.expect(!observer.feed(end_turn_event));
    try std.testing.expect(!observer.feed("event: message_stop\ndata: {}\n\n"));
}

test "response observer preserves Claude SSE state across every split" {
    for (0..end_turn_event.len + 1) |split| {
        var observer = ResponseObserver.init(.claude);
        defer observer.deinit();

        const completed_before_second_chunk = observer.feed(end_turn_event[0..split]);
        const completed_by_second_chunk = observer.feed(end_turn_event[split..]);

        try std.testing.expectEqual(split == end_turn_event.len, completed_before_second_chunk);
        try std.testing.expectEqual(split != end_turn_event.len, completed_by_second_chunk);
    }
}

test "response observer ignores stream closure and tool continuation" {
    var observer = ResponseObserver.init(.claude);
    defer observer.deinit();

    try std.testing.expect(!observer.feed(
        "event: message_delta\n" ++
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n",
    ));
    try std.testing.expect(!observer.feed("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"));
}

test "response observer ignores malformed and truncated SSE input" {
    var observer = ResponseObserver.init(.claude);
    defer observer.deinit();

    try std.testing.expect(!observer.feed("event: message_delta\ndata: not-json\n\n"));

    const oversized = "event: message_delta\ndata: " ++
        ("x" ** (sse.max_data_bytes + 1)) ++ "\n\n";
    try std.testing.expect(!observer.feed(oversized));
}

test "response observer ignores unsupported providers" {
    inline for (.{ AgentProvider.unknown, AgentProvider.codex }) |provider| {
        var observer = ResponseObserver.init(provider);
        defer observer.deinit();

        try std.testing.expect(!observer.feed(end_turn_event));
    }
}

test "response streams decode arbitrarily interleaved HTTP2 payloads independently" {
    const first_split = end_turn_event.len / 3;
    const second_split = 2 * end_turn_event.len / 3;
    var streams = ResponseStreams.init(std.testing.allocator, .claude);
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
    var streams = ResponseStreams.init(std.testing.allocator, .claude);
    defer streams.deinit();

    try std.testing.expect(!streams.feed(7, end_turn_event[0 .. end_turn_event.len / 2]));
    streams.finish(7);
    try std.testing.expect(!streams.feed(7, end_turn_event[end_turn_event.len / 2 ..]));
    streams.finish(7);
    try std.testing.expect(streams.feed(7, end_turn_event));
}

test "response streams reject the connection sentinel and unsupported providers" {
    var claude_streams = ResponseStreams.init(std.testing.allocator, .claude);
    defer claude_streams.deinit();
    try std.testing.expect(!claude_streams.feed(0, end_turn_event));

    var codex_streams = ResponseStreams.init(std.testing.allocator, .codex);
    defer codex_streams.deinit();
    try std.testing.expect(!codex_streams.feed(1, end_turn_event));
}

test "response stream allocation failure drops observation without retaining a slot" {
    var storage: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var streams = ResponseStreams.init(allocator.allocator(), .claude);
    defer streams.deinit();

    try std.testing.expect(!streams.feed(1, end_turn_event));
    try std.testing.expect(streams.find(1) == null);
}

test "response streams degrade locally at their fixed concurrency bound" {
    var streams = ResponseStreams.init(std.testing.allocator, .claude);
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
    std.testing.refAllDecls(request);
}
