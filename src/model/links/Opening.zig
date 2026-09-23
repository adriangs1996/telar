const data = @import("../model.zig");
const opening_support = @import("opening_support.zig");
const Opening = @This();

active: bool = false,
pending: ?data.LinkTarget = null,

pub fn request(self: *Opening, target: data.LinkTarget) opening_support.Request {
    if (!self.active) {
        self.active = true;

        return .{ .start = target };
    }

    self.pending = target;

    return .queued;
}

pub fn complete(self: *Opening) ?data.LinkTarget {
    const next = self.pending;
    self.pending = null;
    self.active = next != null;

    return next;
}

pub fn schedulingFailed(self: *Opening) void {
    self.active = false;
}
