const RetireTabAttachmentsHandler = @This();
const client_model = @import("../../root.zig").model;
const pane_paste = @import("../input/root.zig").pane_paste;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const Effects = @import("TabAttachmentRetirementEffects.zig");
const source_namespace = @import("tab_attachment_retirement.zig");
const std = @import("std");
model: *client_model.Model,
paste_effects: pane_paste.Effects,
focus_effects: pane_focus_reporting.Effects,
effects: Effects,

/// Finishes tab-owned input authorities, delivers every required detach
/// in pane order and commits operational detachment only after all effects.
///
/// ```zig
/// try handler.execute(location);
/// ```
pub fn execute(handler: *RetireTabAttachmentsHandler, location: source_namespace.schema.TabLocation) !void {
    const plan = try handler.model.planTabDetachment(location);

    if (plan.owns_paste) {
        var paste_handler: pane_paste.PanePasteHandler = .{
            .model = handler.model,
            .effects = handler.paste_effects,
        };
        const outcome = try paste_handler.finish();
        std.debug.assert(outcome != .ignored);
    }

    if (plan.owns_reported_focus) {
        var focus_handler: pane_focus_reporting.PaneFocusReportingHandler = .{
            .model = handler.model,
            .effects = handler.focus_effects,
        };
        const outcome = try focus_handler.execute(.clear);
        std.debug.assert(outcome == .applied);
    }

    for (plan.slice()) |pane| {
        const pending = handler.effects.attachment_pending(handler.effects.context, pane.pane_id);
        if (!pane.attached and !pending) {
            continue;
        }

        try handler.effects.detach_pane(handler.effects.context, pane.pane_id);
        handler.effects.retire_attachment(handler.effects.context, pane.pane_id);
        try handler.effects.hide_graphics(handler.effects.context, pane.pane_id);
    }

    try handler.model.commitTabDetachment(plan);
}
