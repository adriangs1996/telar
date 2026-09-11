const ObservePaneInputHandler = @This();
const client_model = @import("../../root.zig").model;
const ObserveEffects = @import("ObserveEffects.zig");
const source_namespace = @import("attachment_prompt.zig");
const key_routing = @import("key_routing.zig");
const attachments = @import("../../attachments/root.zig");
model: *client_model.Model,
effects: ObserveEffects,

/// Mirrors marker deletion and prompt submission only after the child
/// input was accepted by the pane-input boundary. An Enter the editor
/// turns into a newline submits nothing and leaves previews alone.
///
/// ```zig
/// const layout_changed = handler.execute(pane_id, command);
/// ```
pub fn execute(handler: *ObservePaneInputHandler, pane_id: source_namespace.schema.PaneId, command: key_routing.Command) bool {
    const key = switch (command) {
        .bytes => return false,
        .key => |value| value,
    };
    if (key.phase == .release or key.mods.ctrl or key.mods.alt or key.mods.shift) {
        return false;
    }

    const target = handler.effects.visible_target(handler.effects.context) orelse
        handler.model.focusedAttachmentTarget() orelse return false;
    if (target.pane_id != pane_id) {
        return false;
    }

    switch (key.code) {
        .enter => {
            if (handler.effects.prompt_continues(handler.effects.context, target)) {
                return false;
            }

            _ = handler.model.cancelClipboardCapture(target);

            return handler.effects.remove_prompt(handler.effects.context, target) orelse false;
        },
        .backspace, .delete => {
            const deletion: attachments.MarkerDeletion = if (key.code == .backspace) .backward else .forward;
            const id = handler.effects.marker_at_cursor(handler.effects.context, deletion);
            if (id == null) {
                if (handler.effects.pending_marker_at_cursor(handler.effects.context, deletion)) {
                    _ = handler.model.cancelClipboardCapture(target);
                }

                return false;
            }

            return handler.effects.remove(handler.effects.context, id.?) orelse false;
        },
        else => return false,
    }
}
