//! Bounded latest-wins state for host link-opening workers.

const std = @import("std");
const target_mod = @import("target.zig");

pub const Request = union(enum) {
    start: target_mod.Target,
    queued,
};

pub const Opening = struct {
    active: bool = false,
    pending: ?target_mod.Target = null,

    pub fn request(opening: *Opening, target: target_mod.Target) Request {
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
};

test "opening state runs one worker and keeps only the latest request" {
    var opening: Opening = .{};
    const first = try target_mod.Target.init("https://one.example");
    const second = try target_mod.Target.init("https://two.example");
    const third = try target_mod.Target.init("https://three.example");

    try std.testing.expect(opening.request(first) == .start);
    try std.testing.expect(opening.request(second) == .queued);
    try std.testing.expect(opening.request(third) == .queued);
    try std.testing.expectEqualStrings(third.uri(), opening.complete().?.uri());
    try std.testing.expect(opening.active);
    try std.testing.expect(opening.complete() == null);
    try std.testing.expect(!opening.active);
}
