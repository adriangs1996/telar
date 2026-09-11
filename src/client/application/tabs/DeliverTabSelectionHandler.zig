const DeliverTabSelectionHandler = @This();
const client_model = @import("../../root.zig").model;
const pane_paste = @import("../input/root.zig").pane_paste;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");
const Effects = @import("TabSelectionDeliveryEffects.zig");
const std = @import("std");
const source_namespace = @import("tab_selection_delivery.zig");
model: *client_model.Model,
paste_effects: pane_paste.Effects,
focus_effects: pane_focus_reporting.Effects,
attachment_effects: tab_attachment_retirement.Effects,
effects: Effects,

/// Validates one exact selection before retiring the previous tab's
/// resources and activating the selected tab's graphics and snapshot.
///
/// ```zig
/// try handler.execute(selection);
/// ```
pub fn execute(handler: *DeliverTabSelectionHandler, selection: client_model.TabSelection) !void {
    try handler.validate(selection);

    var retire_previous: tab_attachment_retirement.RetireTabAttachmentsHandler = .{
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

fn validate(handler: *const DeliverTabSelectionHandler, selection: client_model.TabSelection) !void {
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

fn exactTab(handler: *const DeliverTabSelectionHandler, location: source_namespace.schema.TabLocation) !*source_namespace.tabs_mod.Tab {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabSelection;
    if (!std.meta.eql(tab.location, location)) {
        return error.StaleTabSelection;
    }

    return tab;
}
