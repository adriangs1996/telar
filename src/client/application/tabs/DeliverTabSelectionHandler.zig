const ModelType = @import("../../model/Model.zig");
const PanePasteEffects = @import("../input/PanePasteEffects.zig");
const PaneFocusReportingEffects = @import("../panes/PaneFocusReportingEffects.zig");
const TabAttachmentRetirementEffects = @import("TabAttachmentRetirementEffects.zig");
const TabSelectionDeliveryEffects = @import("TabSelectionDeliveryEffects.zig");
const TabSelectionType = @import("../../model/TabSelection.zig");
const RetireTabAttachmentsHandlerType = @import("RetireTabAttachmentsHandler.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const TabType = @import("../../workspace/Tab.zig");
const DeliverTabSelectionHandler = @This();

model: *ModelType,
paste_effects: PanePasteEffects,
focus_effects: PaneFocusReportingEffects,
attachment_effects: TabAttachmentRetirementEffects,
effects: TabSelectionDeliveryEffects,

/// Validates one exact selection before retiring the previous tab's
/// resources and activating the selected tab's graphics and snapshot.
///
/// ```zig
/// try handler.execute(selection);
/// ```
pub fn execute(handler: *DeliverTabSelectionHandler, selection: TabSelectionType) !void {
    try handler.validate(selection);

    var retire_previous: RetireTabAttachmentsHandlerType = .{
        .model = handler.model,
        .paste_effects = handler.paste_effects,
        .focus_effects = handler.focus_effects,
        .effects = handler.attachment_effects,
    };
    try retire_previous.execute(selection.previous);

    const selected = try handler.exactTab(selection.selected);
    var panes = selected.model.paneIterator();
    while (panes.next()) |pane| {
        try handler.effects.set_pane_graphics_visible(handler.effects.context, pane.id, true);
    }

    try handler.effects.synchronize_active_resources(handler.effects.context);
    try handler.effects.request_tab_snapshot(handler.effects.context, selection.selected);
}

fn validate(handler: *const DeliverTabSelectionHandler, selection: TabSelectionType) !void {
    if (std.meta.eql(selection.previous, selection.selected)) {
        return error.StaleTabSelection;
    }

    const previous = try handler.exactTab(selection.previous);
    const selected = try handler.exactTab(selection.selected);
    const active = handler.model.workspace.activeConst() orelse return error.StaleTabSelection;
    const version = handler.model.version();
    if (!std.meta.eql(active.location, selection.selected) or
        previous.model.layout.currentRevision() != selection.previous_layout_revision or
        selected.model.layout.currentRevision() != selection.selected_layout_revision or
        version.workspace != selection.workspace_revision or
        version.tabs != selection.tabs_revision or
        version.active_tab != selection.active_tab_revision or
        version.panes != selection.panes_revision or
        version.copy != selection.copy_revision)
    {
        return error.StaleTabSelection;
    }
}

fn exactTab(handler: *const DeliverTabSelectionHandler, location: TabLocationType) !*TabType {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabSelection;
    if (!std.meta.eql(tab.location, location)) {
        return error.StaleTabSelection;
    }

    return tab;
}
