const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const attachments = @import("../../../attachments/root.zig");
const lua_config = @import("../../../config/root.zig");
const graphics = @import("../../../graphics/root.zig");
const input_capability = @import("../../../input/root.zig");
const notifications = @import("../../../notifications/root.zig");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../root.zig");

const copy_mode = input_capability.copy_mode;
const keybind = input_capability.keybind;
const kitty = graphics.kitty;
const schema = core.schema;
const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const workspace_list_mod = workspace_capability.workspace_list;
const ui = core.ui;

test "workspace creation planning requires the attached focused pane" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.planWorkspaceCreation() == null);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectEqual(pane_id, model.planWorkspaceCreation().?);
    model.workspace.findPane(pane_id).?.attached = false;
    try std.testing.expect(model.planWorkspaceCreation() == null);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "tab creation planning captures the workspace and attached focused pane" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.planTabCreation() == null);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectEqualDeep(client_model.TabCreationPlan{
        .workspace = location.workspace,
        .cwd_source = pane_id,
    }, model.planTabCreation().?);
    model.workspace.findPane(pane_id).?.attached = false;
    try std.testing.expect(model.planTabCreation() == null);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "workspace departure commits one empty version and captures bounded client state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const inactive: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const first: schema.PaneId = @enumFromInt(1);
    const focused: schema.PaneId = @enumFromInt(2);
    const third: schema.PaneId = @enumFromInt(3);
    const area: ui.Rect = .{ .w = 40, .h = 10 };
    try model.workspace.bootstrap(first, active, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = focused, .location = active, .axis = .horizontal, .area = area });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = third,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(active.tab_id));

    const departure = model.departWorkspace();

    try std.testing.expectEqualDeep(@as(?schema.WorkspaceLocation, workspace), departure.source);
    try std.testing.expectEqualDeep(active, departure.bookmark.?.location);
    try std.testing.expectEqual(focused, departure.bookmark.?.pane_id);
    try std.testing.expectEqual(focused, departure.bookmark.?.tab_layout.focused().?);
    try std.testing.expectEqualSlices(schema.PaneId, &.{ first, focused, third }, departure.panes.slice());
    try std.testing.expect(model.workspace.workspace == null);
    try std.testing.expectEqual(@as(usize, 0), model.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());

    const version = model.version();
    const repeated = model.departWorkspace();

    try std.testing.expect(repeated.source == null);
    try std.testing.expect(repeated.bookmark == null);
    try std.testing.expectEqual(@as(usize, 0), repeated.panes.slice().len);
    try std.testing.expectEqualDeep(version, model.version());
}

test "workspace arrival commits atomically and stages the saved layout" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(4),
    };
    const left: schema.PaneId = @enumFromInt(10);
    const focused: schema.PaneId = @enumFromInt(11);
    const area: ui.Rect = .{ .w = 60, .h = 12 };
    var saved: layout_mod.Layout = .{};
    try saved.addRoot(left);
    try saved.split(.{ .existing_pane = left, .new_pane = focused, .axis = .horizontal });
    var expected: layout_mod.Snapshot = .{};
    saved.snapshot(area, &expected);

    const activation = try model.arriveWorkspace(.{
        .pane_id = focused,
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
        .saved_layout = saved,
    });

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expectEqual(focused, model.workspace.activeConst().?.model.layout.focused().?);
    try std.testing.expectEqualDeep(client_model.WorkspaceActivation{
        .pane_id = focused,
        .location = location,
        .workspace_revision_before = 0,
        .tabs_revision_before = 0,
        .active_tab_revision_before = 0,
        .panes_revision_before = 0,
        .copy_revision_before = 0,
        .copy_released = false,
        .workspace_revision = 1,
        .tabs_revision = 1,
        .active_tab_revision = 1,
        .panes_revision = 1,
        .copy_revision = 0,
    }, activation);
    try std.testing.expectEqualDeep(client_model.Version{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());

    const snapshot: client_model.TabSnapshot = .{
        .location = location,
        .panes = &.{ left, focused },
    };
    _ = try model.reconcileTab(snapshot, area);
    var actual: layout_mod.Snapshot = .{};
    model.workspace.activeConst().?.model.layout.snapshot(area, &actual);

    try std.testing.expectEqual(focused, model.workspace.activeConst().?.model.layout.focused().?);
    for ([_]schema.PaneId{ left, focused }) |pane_id| {
        try std.testing.expectEqual(expected.find(pane_id).?.outer, actual.find(pane_id).?.outer);
    }
}

test "rejected workspace arrival preserves its previous model and version" {
    var empty = client_model.Model.init(std.testing.allocator, true);
    defer empty.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(4),
    };

    try std.testing.expectError(error.InvalidPaneId, empty.arriveWorkspace(.{
        .pane_id = .invalid,
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expect(empty.workspace.workspace == null);
    try std.testing.expectEqual(@as(usize, 0), empty.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{}, empty.version());

    var occupied = client_model.Model.init(std.testing.allocator, true);
    defer occupied.deinit();
    try occupied.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 30, .rows = 8 });

    try std.testing.expectError(error.ModelNotEmpty, occupied.arriveWorkspace(.{
        .pane_id = @enumFromInt(2),
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqual(@as(usize, 1), occupied.workspace.count);
    try std.testing.expect(occupied.workspace.findPane(@enumFromInt(1)) != null);
    try std.testing.expectEqualDeep(client_model.Version{}, occupied.version());
}

test "workspace replacement commits the confirmed root and captures retired state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const previous_workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const previous: schema.TabLocation = .{
        .workspace = previous_workspace,
        .tab_id = @enumFromInt(1),
    };
    const inactive: schema.TabLocation = .{
        .workspace = previous_workspace,
        .tab_id = @enumFromInt(2),
    };
    const replacement: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(3),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const focused: schema.PaneId = @enumFromInt(2);
    const inactive_pane: schema.PaneId = @enumFromInt(3);
    const replacement_pane: schema.PaneId = @enumFromInt(4);
    try model.workspace.bootstrap(first, previous, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = focused, .location = previous, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(previous.tab_id));

    const committed = try model.replaceWorkspace(.{
        .pane_id = replacement_pane,
        .location = replacement,
        .size = .{ .cols = 30, .rows = 8 },
    });

    try std.testing.expectEqualDeep(@as(?schema.WorkspaceLocation, previous_workspace), committed.departure.source);
    try std.testing.expectEqualDeep(previous, committed.departure.bookmark.?.location);
    try std.testing.expectEqual(focused, committed.departure.bookmark.?.pane_id);
    try std.testing.expectEqualSlices(schema.PaneId, &.{ first, focused, inactive_pane }, committed.departure.panes.slice());
    try std.testing.expectEqualDeep(client_model.WorkspaceActivation{
        .pane_id = replacement_pane,
        .location = replacement,
        .workspace_revision_before = 0,
        .tabs_revision_before = 0,
        .active_tab_revision_before = 0,
        .panes_revision_before = 0,
        .copy_revision_before = 0,
        .copy_released = false,
        .workspace_revision = 1,
        .tabs_revision = 1,
        .active_tab_revision = 1,
        .panes_revision = 1,
        .copy_revision = 0,
    }, committed.activation);
    try std.testing.expectEqualDeep(replacement, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expect(model.workspace.findPane(first) == null);
    try std.testing.expect(model.workspace.findPane(replacement_pane) != null);
    try std.testing.expectEqualDeep(client_model.Version{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());
}

test "workspace replacement captures invalid copy-mode release" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const previous: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const replacement: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), previous, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.enterCopyMode());
    const version_before = model.version();

    const committed = try model.replaceWorkspace(.{
        .pane_id = @enumFromInt(2),
        .location = replacement,
        .size = .{ .cols = 30, .rows = 8 },
    });

    try std.testing.expect(committed.activation.copy_released);
    try std.testing.expectEqual(version_before.copy, committed.activation.copy_revision_before);
    try std.testing.expectEqual(version_before.copy +% 1, committed.activation.copy_revision);
    try std.testing.expect(!model.copyModeActive());
}

test "rejected workspace replacement preserves the occupied projection" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectError(error.WorkspaceAlreadyActive, model.replaceWorkspace(.{
        .pane_id = @enumFromInt(2),
        .location = .{ .workspace = location.workspace, .tab_id = @enumFromInt(2) },
        .size = .{ .cols = 30, .rows = 8 },
    }));
    try std.testing.expectError(error.InvalidPaneId, model.replaceWorkspace(.{
        .pane_id = .invalid,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        },
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expect(model.workspace.findPane(pane_id) != null);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "workspace replacement can recover from an already empty source" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(2),
    };

    const committed = try model.replaceWorkspace(.{
        .pane_id = @enumFromInt(2),
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
    });

    try std.testing.expect(committed.departure.source == null);
    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());
}

test "workspace reconciliation versions semantic dimensions independently" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    const named: client_model.WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "main" },
            .{ .tab_id = second.tab_id, .pane_count = 1, .label = "logs" },
        },
    };
    const name_change = try model.reconcileWorkspace(named);

    try std.testing.expect(name_change.workspace_changed);
    try std.testing.expect(!name_change.tabs_changed);
    try std.testing.expect(!name_change.active_tab_changed);
    try std.testing.expectEqualDeep(client_model.Version{ .workspace = 1 }, model.version());

    const unchanged = try model.reconcileWorkspace(named);

    try std.testing.expect(!unchanged.workspace_changed);
    try std.testing.expect(!unchanged.tabs_changed);
    try std.testing.expect(!unchanged.active_tab_changed);
    try std.testing.expectEqualDeep(client_model.Version{ .workspace = 1 }, model.version());

    const reordered: client_model.WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = second.tab_id, .pane_count = 1, .label = "server" },
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "main" },
        },
    };
    const tabs_change = try model.reconcileWorkspace(reordered);

    try std.testing.expect(!tabs_change.workspace_changed);
    try std.testing.expect(tabs_change.tabs_changed);
    try std.testing.expect(!tabs_change.active_tab_changed);
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqualStrings("server", model.workspace.items[0].?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{ .workspace = 1, .tabs = 1 }, model.version());

    const removed: client_model.WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "main" },
        },
    };
    const active_change = try model.reconcileWorkspace(removed);

    try std.testing.expect(!active_change.workspace_changed);
    try std.testing.expect(active_change.tabs_changed);
    try std.testing.expect(active_change.active_tab_changed);
    try std.testing.expectEqualDeep(second, active_change.previous_active);
    try std.testing.expectEqualDeep(first, active_change.active);
    try std.testing.expectEqualSlices(schema.TabLocation, &.{second}, active_change.removed_tabs.slice());
    try std.testing.expectEqualSlices(schema.PaneId, &.{@enumFromInt(2)}, active_change.removed_panes.slice());
    try std.testing.expectEqualDeep(client_model.Version{ .workspace = 1, .tabs = 2, .active_tab = 1 }, model.version());
    try std.testing.expectEqual(model.version().workspace, active_change.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, active_change.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, active_change.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, active_change.panes_revision);
    try std.testing.expectEqual(model.workspace.activeConst().?.snapshot_loaded, active_change.active_snapshot_loaded);
}

test "rejected workspace snapshots preserve state and revisions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
    const empty: client_model.WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{},
    };

    try std.testing.expectError(error.WorkspaceHasNoTabs, model.reconcileWorkspace(empty));

    const duplicate: client_model.WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = location.tab_id, .pane_count = 1, .label = "main" },
            .{ .tab_id = location.tab_id, .pane_count = 1, .label = "copy" },
        },
    };
    try std.testing.expectError(error.DuplicateTab, model.reconcileWorkspace(duplicate));

    var excessive_tabs: [tabs_mod.max_tabs + 1]client_model.WorkspaceTabInput = undefined;
    for (&excessive_tabs, 0..) |*tab, index| {
        tab.* = .{
            .tab_id = @enumFromInt(@as(u64, @intCast(index + 1))),
            .pane_count = 1,
            .label = "tab",
        };
    }
    const excessive: client_model.WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &excessive_tabs,
    };
    try std.testing.expectError(error.TabLimitReached, model.reconcileWorkspace(excessive));

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expect(model.workspace.findPane(@enumFromInt(1)) != null);
    try std.testing.expectEqualStrings("", model.workspace.workspaceName());
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "active tab reconciliation versions pane changes and reports retired panes" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(first, location, .{ .cols = 20, .rows = 5 });
    const discovered: client_model.TabSnapshot = .{
        .location = location,
        .panes = &.{ first, second },
    };

    const addition = try model.reconcileTab(discovered, .{ .w = 40, .h = 10 });

    try std.testing.expect(addition.active);
    try std.testing.expect(addition.panes_changed);
    try std.testing.expectEqual(@as(usize, 0), addition.removed_panes.slice().len);
    try std.testing.expect(model.workspace.findPane(second) != null);
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 1 }, model.version());
    try std.testing.expectEqualDeep(ui.Rect{ .w = 40, .h = 10 }, addition.area);
    try std.testing.expect(addition.snapshot_loaded);
    try std.testing.expectEqual(model.workspace.activeConst().?.model.layout.currentRevision(), addition.layout_revision);
    try std.testing.expectEqual(model.version().workspace, addition.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, addition.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, addition.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, addition.panes_revision);

    const unchanged = try model.reconcileTab(discovered, .{ .w = 40, .h = 10 });

    try std.testing.expect(!unchanged.panes_changed);
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 1 }, model.version());

    const removed: client_model.TabSnapshot = .{
        .location = location,
        .panes = &.{second},
    };
    const removal = try model.reconcileTab(removed, .{ .w = 40, .h = 10 });

    try std.testing.expect(removal.panes_changed);
    try std.testing.expectEqualSlices(schema.PaneId, &.{first}, removal.removed_panes.slice());
    try std.testing.expect(model.workspace.findPane(first) == null);
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 2 }, model.version());
}

test "tab reconciliation rejects excessive pane membership atomically" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root_pane: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(root_pane, location, .{ .cols = 20, .rows = 5 });
    var pane_ids: [schema.max_panes_per_tab + 1]schema.PaneId = undefined;
    for (&pane_ids, 0..) |*pane_id, index| {
        pane_id.* = @enumFromInt(@as(u64, @intCast(index + 1)));
    }
    const snapshot: client_model.TabSnapshot = .{
        .location = location,
        .panes = &pane_ids,
    };

    try std.testing.expectError(error.TooManyPanes, model.reconcileTab(snapshot, .{ .w = 40, .h = 10 }));

    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(location.tab_id).?.model.pane_count);
    try std.testing.expect(model.workspace.findPane(root_pane) != null);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "inactive tab reconciliation does not advance the visible pane revision" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const inactive: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), active, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(active.tab_id));
    const snapshot: client_model.TabSnapshot = .{
        .location = inactive,
        .panes = &.{ @enumFromInt(2), @enumFromInt(3) },
    };

    const reconciliation = try model.reconcileTab(snapshot, .{ .w = 40, .h = 10 });

    try std.testing.expect(!reconciliation.active);
    try std.testing.expect(reconciliation.panes_changed);
    try std.testing.expect(model.workspace.findPane(@enumFromInt(3)) != null);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
    try std.testing.expect(reconciliation.snapshot_loaded);
    try std.testing.expectEqual(model.workspace.find(inactive.tab_id).?.model.layout.currentRevision(), reconciliation.layout_revision);
    try std.testing.expectEqual(model.version().panes, reconciliation.panes_revision);
}

test "tab reconciliation rejects pane identities owned by another tab" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    const snapshot: client_model.TabSnapshot = .{
        .location = first,
        .panes = &.{ @enumFromInt(1), @enumFromInt(2) },
    };

    try std.testing.expectError(error.PaneAlreadyExists, model.reconcileTab(snapshot, .{ .w = 40, .h = 10 }));

    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(first.tab_id).?.model.pane_count);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(second.tab_id).?.model.pane_count);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "pane attachment confirmation changes only active operational state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const discovered: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.addDiscovered(.{ .pane_id = discovered, .location = location, .area = .{ .w = 40, .h = 10 } });
    const attachment: client_model.PaneAttachment = .{ .pane_id = discovered, .location = location };

    try std.testing.expect(model.needsPaneAttachment(attachment));
    try std.testing.expectEqual(client_model.PaneAttachmentConfirmation.confirmed, model.confirmPaneAttachment(attachment));
    try std.testing.expect(!model.needsPaneAttachment(attachment));
    try std.testing.expect(model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());

    try std.testing.expectEqual(client_model.PaneAttachmentConfirmation.stale, model.confirmPaneAttachment(attachment));
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "pane attachment confirmation ignores inactive missing and wrong-location panes" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const discovered: schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.addDiscovered(.{ .pane_id = discovered, .location = first, .area = .{ .w = 40, .h = 10 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);

    const inactive: client_model.PaneAttachment = .{ .pane_id = discovered, .location = first };
    try std.testing.expectEqual(client_model.PaneAttachmentConfirmation.stale, model.confirmPaneAttachment(inactive));
    try std.testing.expect(!model.needsPaneAttachment(inactive));
    try std.testing.expect(!model.workspace.findPane(discovered).?.attached);

    try std.testing.expect(model.workspace.select(first.tab_id));
    const missing: client_model.PaneAttachment = .{ .pane_id = @enumFromInt(9), .location = first };
    const wrong_location: client_model.PaneAttachment = .{ .pane_id = discovered, .location = second };
    try std.testing.expectEqual(client_model.PaneAttachmentConfirmation.stale, model.confirmPaneAttachment(missing));
    try std.testing.expectEqual(client_model.PaneAttachmentConfirmation.stale, model.confirmPaneAttachment(wrong_location));
    try std.testing.expect(!model.needsPaneAttachment(missing));
    try std.testing.expect(!model.needsPaneAttachment(wrong_location));
    try std.testing.expect(!model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "tab detachment plans exact operational state before a silent commit" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const root: schema.PaneId = @enumFromInt(1);
    const sibling: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(root, first, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.split(.{ .existing_pane = root, .new_pane = sibling, .location = first, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    try std.testing.expect(model.workspace.active().?.model.focusPane(root));
    const root_pane = model.workspace.findPane(root).?;
    const sibling_pane = model.workspace.findPane(sibling).?;
    root_pane.input_modes.bracketed_paste = true;
    root_pane.input_modes.focus_events = true;
    root_pane.pending_frame_id = 7;
    sibling_pane.attached = false;
    sibling_pane.pending_frame_id = 9;
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(3),
    }, .{ .cols = 20, .rows = 5 });

    const plan = try model.planTabDetachment(first);

    try std.testing.expectEqual(@as(usize, 2), plan.slice().len);
    try std.testing.expectEqualDeep(client_model.TabDetachmentPlan.Pane{ .pane_id = root, .attached = true }, plan.slice()[0]);
    try std.testing.expectEqualDeep(client_model.TabDetachmentPlan.Pane{ .pane_id = sibling, .attached = false }, plan.slice()[1]);
    try std.testing.expect(plan.owns_paste);
    try std.testing.expect(plan.owns_reported_focus);
    try std.testing.expect(plan.paste_marker_required);
    try std.testing.expect(plan.focus_out_required);

    var invalid = plan;
    invalid.panes[1] = invalid.panes[0];
    try std.testing.expectError(error.InvalidTabDetachment, model.commitTabDetachment(invalid));

    var unbounded = plan;
    unbounded.len = multiplexer.max_panes + 1;
    try std.testing.expectError(error.InvalidTabDetachment, model.commitTabDetachment(unbounded));

    root_pane.attached = false;
    try std.testing.expectError(error.StaleTabDetachment, model.commitTabDetachment(plan));
    root_pane.attached = true;

    try model.commitTabDetachment(plan);

    try std.testing.expect(!root_pane.attached);
    try std.testing.expect(!sibling_pane.attached);
    try std.testing.expectEqual(@as(u64, 0), root_pane.pending_frame_id);
    try std.testing.expectEqual(@as(u64, 0), sibling_pane.pending_frame_id);
    try std.testing.expect(model.panePasteActive());
    try std.testing.expect(model.reportedPaneFocus() != null);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());

    try std.testing.expectError(error.UnexpectedTab, model.planTabDetachment(.{
        .workspace = workspace,
        .tab_id = @enumFromInt(9),
    }));
}
