const ConfigureGraphicsHandler = @This();
const source_namespace = @import("graphics_configuration.zig");
const ConfigureGraphics = @import("ConfigureGraphics.zig");
attachments: *source_namespace.AttachmentStore,

/// Changes one client attachment aggregate so current and future panes use
/// the same graphics transport policy.
///
/// ```zig
/// const result = try handler.execute(.{ .shared = true });
/// ```
pub fn execute(handler: *ConfigureGraphicsHandler, command: ConfigureGraphics) !source_namespace.ConfigureGraphicsResult {
    return switch (handler.attachments.configureGraphics(command.shared)) {
        .changed => .changed,
        .unchanged => .unchanged,
    };
}
