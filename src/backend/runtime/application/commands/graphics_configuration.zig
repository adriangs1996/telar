//! Application command for one client's graphics transport policy.

const std = @import("std");
const attachment_mod = @import("../../attachment/root.zig");

pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const ConfigureGraphics = @import("ConfigureGraphics.zig");

pub const ConfigureGraphicsResult = enum {
    changed,
    unchanged,
};

pub const ConfigureGraphicsHandler = @import("ConfigureGraphicsHandler.zig");

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
