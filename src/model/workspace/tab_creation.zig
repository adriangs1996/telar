//! A runtime-confirmed tab joins the client's workspace
//! (docs/flows/tab-creation.md).
const core = @import("telar-core");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const Tabs = @import("Tabs.zig");
const WorkspaceLayout = @import("WorkspaceLayout.zig");
const CreatedTab = @import("CreatedTab.zig");

/// Adds a runtime-confirmed tab with its root pane and makes it active.
/// Failure leaves every tab and pane unchanged.
/// Example: `const slot = try tab_creation.add(model, created, size);`
pub fn add(model: *ClientModel, created: CreatedTab, size: core.TerminalSize) !usize {
    const workspace = model.workspace orelse return error.UnexpectedWorkspace;
    if (!std.meta.eql(workspace, created.location.workspace)) {
        return error.UnexpectedWorkspace;
    }

    if (model.tabs.find(created.location.tab_id) != null) {
        return error.TabAlreadyExists;
    }

    if (model.panes.find(created.root_pane_id) != null) {
        return error.PaneAlreadyExists;
    }

    if (model.tabs.count == Tabs.capacity) {
        return error.TabLimitReached;
    }

    if (created.position > model.tabs.count) {
        return error.InvalidTabPosition;
    }

    var layout: WorkspaceLayout = .{};
    _ = layout.setPaneGaps(model.pane_gaps);
    try layout.addRoot(created.root_pane_id);
    if (created.kind == .agent) {
        _ = layout.setSurface(created.root_pane_id, .thread);
    }

    const pane = try model.panes.add(
        model.gpa,
        .{
            .pane_id = created.root_pane_id,
            .location = created.location,
            .size = size,
        },
        true,
    );
    _ = pane.identify(created.kind, created.pane_generation);

    const slot = model.tabs.insert(created.position, created.location, model.pane_gaps);
    model.tabs.layout[slot] = layout;
    model.tabs.setLabel(slot, created.label);
    model.tabs.snapshot_loaded[slot] = true;
    model.tabs.active = slot;
    return slot;
}
