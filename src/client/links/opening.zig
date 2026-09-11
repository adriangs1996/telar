const Opening = @This();
const target_mod = @import("root.zig").target;
const source_namespace = @import("opening_support.zig");
active: bool = false,
pending: ?target_mod.Target = null,

pub fn request(opening: *Opening, target: target_mod.Target) source_namespace.Request {
    if (!opening.active) {
        opening.active = true;

        return .{ .start = target };
    }

    opening.pending = target;

    return .queued;
}

pub fn complete(opening: *Opening) ?target_mod.Target {
    const next = opening.pending;
    opening.pending = null;
    opening.active = next != null;

    return next;
}

pub fn schedulingFailed(opening: *Opening) void {
    opening.active = false;
}
