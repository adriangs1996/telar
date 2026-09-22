const data = @import("../model.zig");
const opening_support = @import("opening_support.zig");
const Opening = @This();

active: bool = false,
pending: ?data.LinkTarget = null,

pub fn request(opening: *Opening, target: data.LinkTarget) opening_support.Request {
    if (!opening.active) {
        opening.active = true;

        return .{ .start = target };
    }

    opening.pending = target;

    return .queued;
}

pub fn complete(opening: *Opening) ?data.LinkTarget {
    const next = opening.pending;
    opening.pending = null;
    opening.active = next != null;

    return next;
}

pub fn schedulingFailed(opening: *Opening) void {
    opening.active = false;
}
