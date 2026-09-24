//! The client leaves one workspace and arrives at another
//! (docs/flows/workspace-handoff.md).
const WorkspaceActivationSeed = @import("../state/WorkspaceActivationSeed.zig");
const WorkspaceReplacement = @import("../state/WorkspaceReplacement.zig");
const workspace_handoff = @import("workspace_handoff.zig");
const model_namespace = @import("../state/model_namespace.zig");
const model_data = @import("../model.zig");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const Panes = @import("../panes/Panes.zig");
const WorkspaceLayout = @import("WorkspaceLayout.zig");
const RootTab = @import("RootTab.zig");

/// Retires every tab and pane of the current workspace.
/// Example: `workspace_handoff.clear(model);`
pub fn clear(model: *ClientModel) void {
    model.panes.deinit();
    model.tabs.count = 0;
    model.tabs.active = 0;
    model.workspace = null;
    model.workspace_name_len = 0;
    model.pending_layout_restore = null;
}

/// Builds the arriving workspace's root tab before retiring the current
/// workspace, so failure preserves every tab and pane.
/// Example: `try workspace_handoff.replaceWithRoot(model, root);`
pub fn replaceWithRoot(model: *ClientModel, root: RootTab) !void {
    var layout: WorkspaceLayout = .{};
    _ = layout.setPaneGaps(model.pane_gaps);
    try layout.addRoot(root.pane_id);

    const pane = try Panes.create(
        model.gpa,
        .{
            .pane_id = root.pane_id,
            .location = root.location,
            .size = root.size,
        },
        true,
    );

    clear(model);
    model.panes.insert(pane);
    const slot = model.tabs.insert(0, root.location, model.pane_gaps);
    model.tabs.layout[slot] = layout;
    model.tabs.restore_display_order[slot] = true;
    model.tabs.active = slot;
    model.workspace = root.location.workspace;
}

/// Builds the first workspace of an empty client.
/// Example: `try workspace_handoff.bootstrap(model, root);`
pub fn bootstrap(model: *ClientModel, root: RootTab) !void {
    if (model.tabs.count != 0) {
        return error.ModelNotEmpty;
    }

    try replaceWithRoot(model, root);
}

test "a failed root construction keeps the previous workspace" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try bootstrap(&model, .{
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = 4, .rows = 2 },
    });

    try std.testing.expectError(error.InvalidPaneId, replaceWithRoot(&model, .{
        .pane_id = .invalid,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(2) },
        .size = .{ .cols = 4, .rows = 2 },
    }));
    try std.testing.expectEqual(@as(usize, 1), model.tabs.count);
    try std.testing.expect(model.panes.find(@enumFromInt(1)) != null);
}

/// Retires the current workspace projection and captures the bounded
/// client state needed by post-commit cleanup and navigation history.
/// An already empty model is an idempotent no-op.
///
/// ```zig
/// const departure = workspace_handoff.depart(model);
/// ```
pub fn depart(model: *ClientModel) model_data.WorkspaceDeparture {
    const departure = model_namespace.captureWorkspace(model);
    if (departure.source == null) {
        model_namespace.releaseInvalidCopyMode(model);
        return departure;
    }

    const active = model.tabs.activeSlot();
    const had_tabs = model.tabs.count != 0;
    const had_active = active != null;
    const had_visible_panes = if (active) |slot| model.panes.countIn(model.tabs.location[slot].tab_id) != 0 else false;
    retainLayouts(model);
    workspace_handoff.clear(model);
    model.workspace_revision +%= 1;
    if (had_tabs) {
        model.tabs_revision +%= 1;
    }
    if (had_active) {
        model.active_tab_revision +%= 1;
    }
    if (had_visible_panes) {
        model.panes_revision +%= 1;
    }
    model_namespace.releaseInvalidCopyMode(model);

    return departure;
}

/// Builds the confirmed root tab transactionally inside an empty client
/// model. Construction failure preserves the empty model and every
/// version.
///
/// ```zig
/// const activation = try workspace_handoff.arrive(model, arrival);
/// ```
pub fn arrive(model: *ClientModel, arrival: model_data.WorkspaceArrival) !model_data.WorkspaceActivation {
    if (model.tabs.count != 0 or model.workspace != null) {
        return error.ModelNotEmpty;
    }

    const version_before = model.version();
    try workspace_handoff.bootstrap(
        model,
        .{
            .pane_id = arrival.pane_id,
            .location = arrival.location,
            .size = arrival.size,
        },
    );
    stageArrival(model, arrival);

    model.workspace_revision +%= 1;
    model.tabs_revision +%= 1;
    model.active_tab_revision +%= 1;
    model.panes_revision +%= 1;
    model_namespace.releaseInvalidCopyMode(model);

    return activationOf(model, .{
        .pane_id = arrival.pane_id,
        .location = arrival.location,
        .version_before = version_before,
    });
}

/// Replaces the current projection with one runtime-created workspace in
/// a single semantic commit. Root construction failure preserves the
/// previous workspace and every version.
///
/// ```zig
/// const replacement = try workspace_handoff.replace(model, arrival);
/// ```
pub fn replace(model: *ClientModel, arrival: model_data.WorkspaceArrival) !WorkspaceReplacement {
    const departure = model_namespace.captureWorkspace(model);
    const version_before = model.version();
    if (departure.source) |source| {
        if (std.meta.eql(source, arrival.location.workspace)) {
            return error.WorkspaceAlreadyActive;
        }
    }

    const saved_before = model.saved_layouts;
    retainLayouts(model);
    errdefer model.saved_layouts = saved_before;
    try workspace_handoff.replaceWithRoot(model, .{
        .pane_id = arrival.pane_id,
        .location = arrival.location,
        .size = arrival.size,
    });
    stageArrival(model, arrival);

    model.workspace_revision +%= 1;
    model.tabs_revision +%= 1;
    model.active_tab_revision +%= 1;
    model.panes_revision +%= 1;
    model_namespace.releaseInvalidCopyMode(model);

    return .{
        .departure = departure,
        .activation = activationOf(model, .{
            .pane_id = arrival.pane_id,
            .location = arrival.location,
            .version_before = version_before,
        }),
    };
}

fn retainLayouts(model: *ClientModel) void {
    const active = model.activeTabLocation() orelse return;
    for (0..model.tabs.count) |slot| {
        // A provisional root must not replace the complete retained tree
        // while its canonical membership response is still pending.
        if (!model.tabs.snapshot_loaded[slot]) {
            continue;
        }

        const location = model.tabs.location[slot];
        const focused = model.tabs.layout[slot].focused() orelse continue;
        model.saved_layouts.retain(.{
            .location = location,
            .pane_id = focused,
            .workspace_active = std.meta.eql(active, location),
            .layout = model.tabs.layout[slot],
        });
    }
}

fn stageArrival(model: *ClientModel, arrival: model_data.WorkspaceArrival) void {
    const saved_layout = if (model.saved_layouts.find(arrival.location)) |saved| saved.layout else arrival.saved_layout;
    if (saved_layout) |saved| {
        std.debug.assert(model.tabs.find(arrival.location.tab_id) != null);
        model.pending_layout_restore = .{
            .location = arrival.location,
            .layout = saved,
        };
    }
}

fn activationOf(model: *const ClientModel, seed: WorkspaceActivationSeed) model_data.WorkspaceActivation {
    return .{
        .pane_id = seed.pane_id,
        .location = seed.location,
        .workspace_revision_before = seed.version_before.workspace,
        .tabs_revision_before = seed.version_before.tabs,
        .active_tab_revision_before = seed.version_before.active_tab,
        .panes_revision_before = seed.version_before.panes,
        .copy_revision_before = seed.version_before.copy,
        .copy_released = model.copy_revision != seed.version_before.copy,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    };
}
