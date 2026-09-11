const AttachmentStoreType = @import("../../attachment/AttachmentStore.zig");
const ConfigureGraphics = @import("ConfigureGraphics.zig");
const graphics_configuration = @import("graphics_configuration.zig");
const ConfigureGraphicsHandler = @This();

attachments: *AttachmentStoreType,

/// Changes one client attachment aggregate so current and future panes use
/// the same graphics transport policy.
///
/// ```zig
/// const result = try handler.execute(.{ .shared = true });
/// ```
pub fn execute(handler: *ConfigureGraphicsHandler, command: ConfigureGraphics) !graphics_configuration.ConfigureGraphicsResult {
    return switch (handler.attachments.configureGraphics(command.shared)) {
        .changed => .changed,
        .unchanged => .unchanged,
    };
}
