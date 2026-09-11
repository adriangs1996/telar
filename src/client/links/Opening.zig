const TargetType = @import("LinkTarget.zig");
const opening_support = @import("opening_support.zig");
const Opening = @This();

active: bool = false,
pending: ?TargetType = null,

pub fn request(opening: *Opening, target: TargetType) opening_support.Request {
    if (!opening.active) {
        opening.active = true;

        return .{ .start = target };
    }

    opening.pending = target;

    return .queued;
}

pub fn complete(opening: *Opening) ?TargetType {
    const next = opening.pending;
    opening.pending = null;
    opening.active = next != null;

    return next;
}

pub fn schedulingFailed(opening: *Opening) void {
    opening.active = false;
}
