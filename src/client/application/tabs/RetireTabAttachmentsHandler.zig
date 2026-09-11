const ModelType = @import("../../model/Model.zig");
const PanePasteEffects = @import("../input/PanePasteEffects.zig");
const PaneFocusReportingEffects = @import("../panes/PaneFocusReportingEffects.zig");
const TabAttachmentRetirementEffects = @import("TabAttachmentRetirementEffects.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PanePasteHandlerType = @import("../input/PanePasteHandler.zig");
const std = @import("std");
const PaneFocusReportingHandlerType = @import("../panes/PaneFocusReportingHandler.zig");
const RetireTabAttachmentsHandler = @This();

model: *ModelType,
paste_effects: PanePasteEffects,
focus_effects: PaneFocusReportingEffects,
effects: TabAttachmentRetirementEffects,

/// Finishes tab-owned input authorities, delivers every required detach
/// in pane order and commits operational detachment only after all effects.
///
/// ```zig
/// try handler.execute(location);
/// ```
pub fn execute(handler: *RetireTabAttachmentsHandler, location: TabLocationType) !void {
    const plan = try handler.model.planTabDetachment(location);

    if (plan.owns_paste) {
        var paste_handler: PanePasteHandlerType = .{
            .model = handler.model,
            .effects = handler.paste_effects,
        };
        const outcome = try paste_handler.finish();
        std.debug.assert(outcome != .ignored);
    }

    if (plan.owns_reported_focus) {
        var focus_handler: PaneFocusReportingHandlerType = .{
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
