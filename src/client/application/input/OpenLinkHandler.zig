const OpenLinkEffects = @import("OpenLinkEffects.zig");
const TargetType = @import("../../links/LinkTarget.zig");
const FilePathType = @import("../../links/FilePath.zig");
const OpenLinkHandler = @This();

effects: OpenLinkEffects,

/// Converts file URIs before dispatch and keeps host URLs unchanged.
///
/// ```zig
/// try handler.execute(target);
/// ```
pub fn execute(handler: *OpenLinkHandler, target: TargetType) !void {
    switch (target.scheme) {
        .file => try handler.effects.open_file(
            handler.effects.context,
            try FilePathType.init(&target),
        ),
        .http, .https => try handler.effects.open_external(handler.effects.context, target),
    }
}
