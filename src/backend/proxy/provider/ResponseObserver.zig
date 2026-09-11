const types = @import("../../agent/types.zig");
const DecoderType = @import("../Decoder.zig");
const SseEvent = @import("../SseEvent.zig");
const std = @import("std");
const claude = @import("claude.zig");
/// Bounded interpreter for one streamed provider response.
const ResponseObserver = @This();

dialect: types.ApiDialect = .unknown,
decoder: DecoderType = .{},
completed: bool = false,

/// Starts observing one response from `provider`.
///
/// ```zig
/// var observer = ResponseObserver.init(.anthropic_messages);
/// defer observer.deinit();
/// ```
pub fn init(dialect: types.ApiDialect) ResponseObserver {
    return .{ .dialect = dialect };
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
    if (observer.completed or observer.dialect != .anthropic_messages) {
        return false;
    }

    const EventSink = struct {
        observer: *ResponseObserver,

        pub fn emit(sink: *@This(), event: SseEvent) void {
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

fn inspectEvent(observer: *ResponseObserver, event: SseEvent) void {
    if (claude.completesTurn(event)) {
        observer.completed = true;
    }
}
