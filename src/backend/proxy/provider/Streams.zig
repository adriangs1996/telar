/// Bounded collection of request observers keyed by HTTP/2 stream ID.
const Streams = @This();
const Observer = @import("Observer.zig");
const source_namespace = @import("request_body.zig");
const Fragment = @import("Fragment.zig");
const Slot = struct {
    stream_id: u32 = 0,
    observer: Observer = .{},
};

dialect: source_namespace.ApiDialect,
slots: [source_namespace.max_concurrent_requests]Slot = @splat(.{}),

/// Creates an empty per-connection observer set.
///
/// ```zig
/// var streams = Streams.init(.anthropic_messages);
/// defer streams.deinit();
/// ```
pub fn init(dialect: source_namespace.ApiDialect) Streams {
    return .{ .dialect = dialect };
}

/// Starts observing one candidate stream. Duplicate, zero, and
/// capacity-exhausted stream IDs return `false` without replacing state.
///
/// ```zig
/// const observing = streams.start(stream_id);
/// ```
pub fn start(streams: *Streams, stream_id: u32) bool {
    if (stream_id == 0 or streams.dialect == .unknown) {
        return false;
    }

    var free: ?*Slot = null;

    for (&streams.slots) |*slot| {
        if (slot.stream_id == stream_id) {
            return false;
        }

        if (slot.stream_id == 0 and free == null) {
            free = slot;
        }
    }

    const slot = free orelse return false;
    slot.stream_id = stream_id;
    slot.observer.init(streams.dialect);
    return true;
}

/// Feeds a fragment to its matching stream. Unknown streams are ignored.
///
/// ```zig
/// streams.feed(.{ .stream_id = stream_id, .bytes = fragment });
/// ```
pub fn feed(streams: *Streams, fragment: Fragment) void {
    const slot = streams.find(fragment.stream_id) orelse return;
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
pub fn finish(streams: *Streams, stream_id: u32) ?source_namespace.RequestClass {
    const slot = streams.find(stream_id) orelse return null;
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
pub fn discard(streams: *Streams, stream_id: u32) void {
    const slot = streams.find(stream_id) orelse return;
    slot.observer.deinit();
    slot.* = .{};
}

/// Erases every stream still owned by the connection.
///
/// ```zig
/// streams.deinit();
/// ```
pub fn deinit(streams: *Streams) void {
    for (&streams.slots) |*slot| {
        if (slot.stream_id == 0) {
            continue;
        }

        slot.observer.deinit();
        slot.* = .{};
    }

    streams.dialect = .unknown;
}

fn find(streams: *Streams, stream_id: u32) ?*Slot {
    for (&streams.slots) |*slot| {
        if (slot.stream_id == stream_id) {
            return slot;
        }
    }

    return null;
}
