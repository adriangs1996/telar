//! Bounded latest-wins state for host link-opening workers.

const TargetType = @import("LinkTarget.zig");
const Opening = @import("Opening.zig");
const std = @import("std");

pub const Request = union(enum) {
    start: TargetType,
    queued,
};

test "opening state runs one worker and keeps only the latest request" {
    var opening: Opening = .{};
    const first = try TargetType.init("https://one.example");
    const second = try TargetType.init("https://two.example");
    const third = try TargetType.init("https://three.example");

    try std.testing.expect(opening.request(first) == .start);
    try std.testing.expect(opening.request(second) == .queued);
    try std.testing.expect(opening.request(third) == .queued);
    try std.testing.expectEqualStrings(third.uri(), opening.complete().?.uri());
    try std.testing.expect(opening.active);
    try std.testing.expect(opening.complete() == null);
    try std.testing.expect(!opening.active);
}
