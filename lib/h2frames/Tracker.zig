const std = @import("std");
const streams = @import("streams.zig");
const Response = @import("Response.zig");
const Tracker = @This();

responses: [streams.max_tracked_streams]Response = @splat(.{
    .stream_id = 0,
    .status_code = 0,
    .sse_body = false,
}),
requests: [streams.max_tracked_streams]u32 = @splat(0),

pub fn startRequest(self: *Tracker, stream_id: u32) bool {
    if (stream_id == 0) {
        return false;
    }

    var free: ?*u32 = null;

    for (&self.requests) |*slot| {
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

/// Whether every request slot holds a stream, so a new one goes untracked.
///
/// ```zig
/// if (!tracker.startRequest(id) and tracker.requestsFull()) untracked += 1;
/// ```
pub fn requestsFull(self: *const Tracker) bool {
    return std.mem.indexOfScalar(u32, &self.requests, 0) == null;
}

pub fn finishRequest(self: *Tracker, stream_id: u32) void {
    for (&self.requests) |*slot| {
        if (slot.* != stream_id) {
            continue;
        }

        slot.* = 0;
        return;
    }
}

pub fn setResponse(self: *Tracker, response: Response) bool {
    if (response.stream_id == 0) {
        return false;
    }

    var free: ?*Response = null;

    for (&self.responses) |*entry| {
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

pub fn status(self: *const Tracker, stream_id: u32) u16 {
    for (self.responses) |entry| {
        if (entry.stream_id == stream_id) {
            return entry.status_code;
        }
    }

    return 0;
}

pub fn hasObservableSseBody(self: *const Tracker, stream_id: u32) bool {
    for (self.responses) |entry| {
        if (entry.stream_id == stream_id) {
            return entry.sse_body;
        }
    }

    return false;
}

pub fn hasActiveResponses(self: *const Tracker) bool {
    for (self.responses) |entry| {
        if (entry.stream_id != 0) {
            return true;
        }
    }

    return false;
}

pub fn finishResponse(self: *Tracker, stream_id: u32) void {
    for (&self.responses) |*entry| {
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
