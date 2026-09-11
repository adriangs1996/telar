const DismissAttachmentHandler = @This();
const DismissEffects = @import("DismissEffects.zig");
const attachments = @import("../../attachments/root.zig");
effects: DismissEffects,

/// Deletes the child marker before retiring its paired local preview.
///
/// ```zig
/// const layout_changed = try handler.execute(id);
/// ```
pub fn execute(handler: *DismissAttachmentHandler, id: attachments.Id) !bool {
    const command = handler.effects.plan(handler.effects.context, id) orelse return false;
    try handler.effects.deliver(handler.effects.context, command);

    return handler.effects.remove(handler.effects.context, id) orelse false;
}
