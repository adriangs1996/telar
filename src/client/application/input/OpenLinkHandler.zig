const OpenLinkHandler = @This();
const Effects = @import("OpenLinkEffects.zig");
const link_capability = @import("../../links/root.zig");
effects: Effects,

/// Converts file URIs before dispatch and keeps host URLs unchanged.
///
/// ```zig
/// try handler.execute(target);
/// ```
pub fn execute(handler: *OpenLinkHandler, target: link_capability.Target) !void {
    switch (target.scheme) {
        .file => try handler.effects.open_file(
            handler.effects.context,
            try link_capability.FilePath.init(&target),
        ),
        .http, .https => try handler.effects.open_external(handler.effects.context, target),
    }
}
