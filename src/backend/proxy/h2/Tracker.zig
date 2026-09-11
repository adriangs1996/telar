const Tracker = @This();
const source_namespace = @import("streams.zig");
const Response = @import("Response.zig");
responses: [source_namespace.max_tracked_streams]Response = @splat(.{
    .stream_id = 0,
    .status_code = 0,
    .sse_body = false,
}),
requests: [source_namespace.max_tracked_streams]u32 = @splat(0),

pub fn startRequest(tracker: *Tracker, stream_id: u32) bool {
    if (stream_id == 0) {
        return false;
    }

    var free: ?*u32 = null;

    for (&tracker.requests) |*slot| {
        if (slot.* == stream_id) {
            return false;
        }

        if (slot.* == 0 and free == null) {
            free = slot;
        }
    }

    const destination = free orelse return false;
    destination.* = stream_id;
    return true;
}

pub fn finishRequest(tracker: *Tracker, stream_id: u32) void {
    for (&tracker.requests) |*slot| {
        if (slot.* != stream_id) {
            continue;
        }

        slot.* = 0;
        return;
    }
}

pub fn setResponse(tracker: *Tracker, response: Response) bool {
    if (response.stream_id == 0) {
        return false;
    }

    var free: ?*Response = null;

    for (&tracker.responses) |*entry| {
        if (entry.stream_id == response.stream_id) {
            entry.* = response;
            return true;
        }

        if (entry.stream_id == 0 and free == null) {
            free = entry;
        }
    }

    const destination = free orelse return false;
    destination.* = response;
    return true;
}

pub fn status(tracker: *const Tracker, stream_id: u32) u16 {
    for (tracker.responses) |entry| {
        if (entry.stream_id == stream_id) {
            return entry.status_code;
        }
    }

    return 0;
}

pub fn hasObservableSseBody(tracker: *const Tracker, stream_id: u32) bool {
    for (tracker.responses) |entry| {
        if (entry.stream_id == stream_id) {
            return entry.sse_body;
        }
    }

    return false;
}

pub fn hasActiveResponses(tracker: *const Tracker) bool {
    for (tracker.responses) |entry| {
        if (entry.stream_id != 0) {
            return true;
        }
    }

    return false;
}

pub fn finishResponse(tracker: *Tracker, stream_id: u32) void {
    for (&tracker.responses) |*entry| {
        if (entry.stream_id != stream_id) {
            continue;
        }

        entry.* = .{
            .stream_id = 0,
            .status_code = 0,
            .sse_body = false,
        };
        return;
    }
}
