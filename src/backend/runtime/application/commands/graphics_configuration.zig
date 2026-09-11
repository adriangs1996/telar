//! Application command for one client's graphics transport policy.

const AttachmentStore = @import("../../attachment/AttachmentStore.zig");
const ConfigureGraphicsHandler = @import("ConfigureGraphicsHandler.zig");
const std = @import("std");

pub const ConfigureGraphicsResult = enum {
    changed,
    unchanged,
};

test "ConfigureGraphicsHandler is idempotent on an empty client aggregate" {
    var attachments: AttachmentStore = .{};
    var handler: ConfigureGraphicsHandler = .{ .attachments = &attachments };

    try std.testing.expectEqual(
        ConfigureGraphicsResult.changed,
        try handler.execute(.{ .shared = true }),
    );
    try std.testing.expectEqual(
        ConfigureGraphicsResult.unchanged,
        try handler.execute(.{ .shared = true }),
    );
}
