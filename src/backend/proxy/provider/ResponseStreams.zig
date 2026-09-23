const std = @import("std");
const types = @import("../../agent/types.zig");
const provider = @import("provider.zig");
const ResponseObserver = @import("ResponseObserver.zig");
/// Bounded collection of response interpreters keyed by HTTP/2 stream ID.
const ResponseStreams = @This();

allocator: std.mem.Allocator,
dialect: types.ApiDialect,
slots: [provider.max_concurrent_responses]ResponseStreamsSlot = @splat(.{}),

/// Starts an empty set for one provider connection.
///
/// ```zig
/// var streams = ResponseStreams.init(allocator, .anthropic_messages);
/// defer streams.deinit();
/// ```
pub fn init(allocator: std.mem.Allocator, dialect: types.ApiDialect) ResponseStreams {
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
pub fn feed(self: *ResponseStreams, stream_id: u32, input: []const u8) bool {
    if (stream_id == 0 or self.dialect != .anthropic_messages) {
        return false;
    }

    const slot = self.find(stream_id) orelse self.create(stream_id) orelse return false;
    return slot.response.?.feed(input);
}

/// Erases the parser state retained for a completed or failed stream.
///
/// ```zig
/// streams.finish(stream_id);
/// ```
pub fn finish(self: *ResponseStreams, stream_id: u32) void {
    const slot = self.find(stream_id) orelse return;
    const response = slot.response orelse return;
    response.deinit();
    self.allocator.destroy(response);
    slot.* = .{};
}

/// Securely erases every retained stream fragment.
///
/// ```zig
/// streams.deinit();
/// ```
pub fn deinit(self: *ResponseStreams) void {
    for (&self.slots) |*slot| {
        const response = slot.response orelse continue;
        response.deinit();
        self.allocator.destroy(response);
        slot.* = .{};
    }

    self.dialect = .unknown;
}

pub fn find(self: *ResponseStreams, stream_id: u32) ?*ResponseStreamsSlot {
    for (&self.slots) |*slot| {
        if (slot.stream_id == stream_id) {
            return slot;
        }
    }

    return null;
}

fn create(self: *ResponseStreams, stream_id: u32) ?*ResponseStreamsSlot {
    for (&self.slots) |*slot| {
        if (slot.stream_id != 0) {
            continue;
        }

        const response = self.allocator.create(ResponseObserver) catch return null;
        response.* = .init(self.dialect);
        slot.* = .{
            .stream_id = stream_id,
            .response = response,
        };
        return slot;
    }

    return null;
}

const ResponseStreamsSlot = struct {
    stream_id: u32 = 0,
    response: ?*ResponseObserver = null,
};
