/// Bounded collection of response interpreters keyed by HTTP/2 stream ID.
const ResponseStreams = @This();
const ResponseObserver = @import("ResponseObserver.zig");
const std = @import("std");
const source_namespace = @import("root.zig");
const Slot = struct {
    stream_id: u32 = 0,
    response: ?*ResponseObserver = null,
};

allocator: std.mem.Allocator,
dialect: source_namespace.ApiDialect,
slots: [source_namespace.max_concurrent_responses]Slot = @splat(.{}),

/// Starts an empty set for one provider connection.
///
/// ```zig
/// var streams = ResponseStreams.init(allocator, .anthropic_messages);
/// defer streams.deinit();
/// ```
pub fn init(allocator: std.mem.Allocator, dialect: source_namespace.ApiDialect) ResponseStreams {
    return .{ .allocator = allocator, .dialect = dialect };
}

/// Feeds one response payload fragment to its stream and reports a newly
/// verified completion exactly once for that stream.
///
/// A zero stream ID, unsupported provider, or capacity exhaustion drops
/// only semantic observation; transport forwarding remains unaffected.
///
/// ```zig
/// if (streams.feed(stream_id, bytes)) {
///     publishCompletion(stream_id);
/// }
/// ```
pub fn feed(streams: *ResponseStreams, stream_id: u32, input: []const u8) bool {
    if (stream_id == 0 or streams.dialect != .anthropic_messages) {
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

    streams.dialect = .unknown;
}

pub fn find(streams: *ResponseStreams, stream_id: u32) ?*Slot {
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
        response.* = .init(streams.dialect);
        slot.* = .{
            .stream_id = stream_id,
            .response = response,
        };
        return slot;
    }

    return null;
}
