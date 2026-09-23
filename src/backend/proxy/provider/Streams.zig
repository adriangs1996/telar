const types = @import("../../agent/types.zig");
const request_body = @import("request_body.zig");
const Observer = @import("Observer.zig");
const Fragment = @import("Fragment.zig");
const request_support = @import("request_support.zig");
/// Bounded collection of request observers keyed by HTTP/2 stream ID.
const Streams = @This();

dialect: types.ApiDialect,
slots: [request_body.max_concurrent_requests]StreamsSlot = @splat(.{}),

/// Creates an empty per-connection observer set.
///
/// ```zig
/// var streams = Streams.init(.anthropic_messages);
/// defer streams.deinit();
/// ```
pub fn init(dialect: types.ApiDialect) Streams {
    return .{ .dialect = dialect };
}

/// Starts observing one candidate stream. Duplicate, zero, and
/// capacity-exhausted stream IDs return `false` without replacing state.
///
/// ```zig
/// const observing = streams.start(stream_id);
/// ```
pub fn start(self: *Streams, stream_id: u32) bool {
    if (stream_id == 0 or self.dialect == .unknown) {
        return false;
    }

    var free: ?*StreamsSlot = null;

    for (&self.slots) |*slot| {
        if (slot.stream_id == stream_id) {
            return false;
        }

        if (slot.stream_id == 0 and free == null) {
            free = slot;
        }
    }

    const slot = free orelse return false;
    slot.stream_id = stream_id;
    slot.observer.init(self.dialect);
    return true;
}

/// Feeds a fragment to its matching stream. Unknown streams are ignored.
///
/// ```zig
/// streams.feed(.{ .stream_id = stream_id, .bytes = fragment });
/// ```
pub fn feed(self: *Streams, fragment: Fragment) void {
    const slot = self.find(fragment.stream_id) orelse return;
    slot.observer.feed(fragment.bytes);
}

/// Finishes and erases one stream, returning its classification when it
/// was actively observed.
///
/// ```zig
/// if (streams.finish(stream_id)) |classification| {
///     publish(classification);
/// }
/// ```
pub fn finish(self: *Streams, stream_id: u32) ?request_support.RequestClass {
    const slot = self.find(stream_id) orelse return null;
    const classification = slot.observer.finish();
    slot.observer.deinit();
    slot.* = .{};
    return classification;
}

/// Erases one interrupted stream without attempting classification.
///
/// ```zig
/// streams.discard(stream_id);
/// ```
pub fn discard(self: *Streams, stream_id: u32) void {
    const slot = self.find(stream_id) orelse return;
    slot.observer.deinit();
    slot.* = .{};
}

/// Erases every stream still owned by the connection.
///
/// ```zig
/// streams.deinit();
/// ```
pub fn deinit(self: *Streams) void {
    for (&self.slots) |*slot| {
        if (slot.stream_id == 0) {
            continue;
        }

        slot.observer.deinit();
        slot.* = .{};
    }

    self.dialect = .unknown;
}

fn find(self: *Streams, stream_id: u32) ?*StreamsSlot {
    for (&self.slots) |*slot| {
        if (slot.stream_id == stream_id) {
            return slot;
        }
    }

    return null;
}

const StreamsSlot = struct {
    stream_id: u32 = 0,
    observer: Observer = .{},
};
