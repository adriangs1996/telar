const ModelType = @import("../../model/Model.zig");
const PanePasteEffects = @import("../input/PanePasteEffects.zig");
const PaneFocusReportingEffects = @import("../panes/PaneFocusReportingEffects.zig");
const TabAttachmentRetirementEffects = @import("TabAttachmentRetirementEffects.zig");
const TabCreationDeliveryEffects = @import("TabCreationDeliveryEffects.zig");
const TabCreationType = @import("../../model/TabCreation.zig");
const RetireTabAttachmentsHandlerType = @import("RetireTabAttachmentsHandler.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const TabType = @import("../../workspace/Tab.zig");
const DeliverTabCreationHandler = @This();

model: *ModelType,
paste_effects: PanePasteEffects,
focus_effects: PaneFocusReportingEffects,
attachment_effects: TabAttachmentRetirementEffects,
effects: TabCreationDeliveryEffects,

/// Validates one exact creation before retiring the previous tab's
/// attachments and synchronizing resources for the created root pane.
///
/// ```zig
/// try handler.execute(creation);
/// ```
pub fn execute(handler: *DeliverTabCreationHandler, creation: TabCreationType) !void {
    try handler.validate(creation);

    var retire_previous: RetireTabAttachmentsHandlerType = .{
        .model = handler.model,
        .paste_effects = handler.paste_effects,
        .focus_effects = handler.focus_effects,
        .effects = handler.attachment_effects,
    };
    try retire_previous.execute(creation.previous);

    try handler.effects.synchronize_active_resources(handler.effects.context);
}

fn validate(handler: *const DeliverTabCreationHandler, creation: TabCreationType) !void {
    if (std.meta.eql(creation.previous, creation.created)) {
        return error.StaleTabCreation;
    }

    const previous = try handler.exactTab(creation.previous);
    const created = try handler.exactTab(creation.created);
    const active = handler.model.workspace.activeConst() orelse return error.StaleTabCreation;
    const root = created.model.findConst(creation.created_root_pane_id) orelse return error.StaleTabCreation;
    const version = handler.model.version();
    if (!std.meta.eql(active.location, creation.created) or
        handler.model.workspace.indexOf(creation.created.tab_id) != @as(usize, creation.created_position) or
        previous.model.layout.currentRevision() != creation.previous_layout_revision or
        created.model.layout.currentRevision() != creation.created_layout_revision or
        created.model.pane_count != 1 or
        created.model.layout.focused() != creation.created_root_pane_id or
        !std.meta.eql(root.location, creation.created) or
        !root.attached or
        !created.snapshot_loaded or
        handler.model.copyModeActive() or
        version.workspace != creation.workspace_revision or
        version.tabs != creation.tabs_revision or
        version.active_tab != creation.active_tab_revision or
        version.panes != creation.panes_revision or
        version.copy != creation.copy_revision or
        creation.tabs_revision_before +% 1 != creation.tabs_revision or
        creation.active_tab_revision_before +% 1 != creation.active_tab_revision or
        creation.copy_revision_before +% @intFromBool(creation.copy_released) != creation.copy_revision)
    {
        return error.StaleTabCreation;
    }
}

fn exactTab(handler: *const DeliverTabCreationHandler, location: TabLocationType) !*TabType {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabCreation;
    if (!std.meta.eql(tab.location, location)) {
        return error.StaleTabCreation;
    }

    return tab;
}
