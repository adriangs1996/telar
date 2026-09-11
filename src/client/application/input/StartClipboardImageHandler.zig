const StartClipboardImageHandler = @This();
const client_model = @import("../../root.zig").model;
const StartEffects = @import("ClipboardImageStartEffects.zig");
const source_namespace = @import("clipboard_image.zig");
const std = @import("std");
model: *client_model.Model,
effects: StartEffects,

/// Resolves one supported focused target and commits its capture identity
/// before scheduling the media worker.
///
/// ```zig
/// const outcome = try handler.execute(platform_supported);
/// ```
pub fn execute(handler: *StartClipboardImageHandler, platform_supported: bool) !source_namespace.StartOutcome {
    if (!platform_supported) {
        return .unsupported;
    }

    const target = handler.model.focusedAttachmentTarget() orelse return .no_target;
    const capture = (try handler.model.beginClipboardCapture(target)) orelse return .busy;
    errdefer {
        const rolled_back = handler.model.finishClipboardCapture(capture.id);
        std.debug.assert(rolled_back != null);
    }

    try handler.effects.schedule(handler.effects.context, capture);
    return .{ .started = capture };
}
