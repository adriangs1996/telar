//! A runtime-confirmed tab joins the client's workspace
//! (docs/flows/tab-creation.md).
const TabCreationPlan = @import("../state/TabCreationPlan.zig");
const NewTab = @import("../state/NewTab.zig");
const tab_creation = @import("tab_creation.zig");
const model_namespace = @import("../state/model_namespace.zig");
const model_data = @import("../model.zig");
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

    const pane = try model.panes.add(
        model.gpa,
        .{
            .pane_id = created.root_pane_id,
            .location = created.location,
            .size = size,
        },
        true,
    );
    _ = pane.identify(created.pane_generation);

    const slot = model.tabs.insert(created.position, created.location, model.pane_gaps);
    model.tabs.layout[slot] = layout;
    model.tabs.setLabel(slot, created.label);
    model.tabs.snapshot_loaded[slot] = true;
    model.tabs.active = slot;
    return slot;
}

/// Commits a runtime-confirmed tab and makes its identity active.
///
/// ```zig
/// const creation = try tab_creation.create(model, command);
/// ```
pub fn create(model: *ClientModel, command: NewTab) !model_data.TabCreation {
    const previous = model.tabs.activeSlot() orelse return error.NoActiveTab;
    const previous_location = model.tabs.location[previous];
    const previous_layout_revision = model.tabs.layout[previous].currentRevision();
    const tabs_revision_before = model.tabs_revision;
    const active_tab_revision_before = model.active_tab_revision;
    const copy_revision_before = model.copy_revision;

    const created = try tab_creation.add(model, command.created, command.size);
    model.tabs_revision +%= 1;
    model.active_tab_revision +%= 1;
    model_namespace.releaseInvalidCopyMode(model);

    return .{
        .previous = previous_location,
        .created = command.created.location,
        .created_root_pane_id = command.created.root_pane_id,
        .created_position = command.created.position,
        .previous_layout_revision = previous_layout_revision,
        .created_layout_revision = model.tabs.layout[created].currentRevision(),
        .tabs_revision_before = tabs_revision_before,
        .active_tab_revision_before = active_tab_revision_before,
        .copy_revision_before = copy_revision_before,
        .copy_released = model.copy_revision != copy_revision_before,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    };
}

/// Captures the current workspace and attached focused pane for a tab
/// creation request without changing client state.
///
/// ```zig
/// const plan = tab_creation.planCreation(model) orelse return;
/// ```
pub fn planCreation(model: *const ClientModel) ?TabCreationPlan {
    const source = model_namespace.focusedLaunchSource(model) orelse return null;

    return .{
        .workspace = source.location.workspace,
        .cwd_source = source.pane_id,
    };
}
