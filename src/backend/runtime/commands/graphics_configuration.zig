//! Application command for one client's graphics transport policy.

const std = @import("std");
const attachment_mod = @import("../attachment.zig");

const AttachmentStore = attachment_mod.AttachmentStore;

pub const ConfigureGraphics = struct {
    shared: bool,
};

pub const ConfigureGraphicsResult = enum {
    changed,
    unchanged,
};

pub const ConfigureGraphicsHandler = struct {
    attachments: *AttachmentStore,

    /// Changes one client attachment aggregate so current and future panes use
    /// the same graphics transport policy.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .shared = true });
    /// ```
    pub fn execute(handler: *ConfigureGraphicsHandler, command: ConfigureGraphics) !ConfigureGraphicsResult {
        return switch (handler.attachments.configureGraphics(command.shared)) {
            .changed => .changed,
            .unchanged => .unchanged,
        };
    }
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
