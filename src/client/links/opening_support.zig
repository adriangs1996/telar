//! Bounded latest-wins state for host link-opening workers.

const std = @import("std");
const target_mod = @import("root.zig").target;

pub const Request = union(enum) {
    start: target_mod.Target,
    queued,
};

pub const Opening = @import("Opening.zig");

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
