const ModelType = @import("../Model.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const VersionType = @import("../Version.zig");
const TabCreationPlanType = @import("../TabCreationPlan.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const RectType = @import("telar-core").Rect;
const LayoutType = @import("../../workspace/WorkspaceLayout.zig");
const LayoutSnapshot = @import("../../workspace/LayoutSnapshot.zig");
const WorkspaceActivationType = @import("../WorkspaceActivation.zig");
const PaneSnapshot = @import("../../workspace/PaneSnapshot.zig");
const max_client_layout_nodes_module = @import("telar-core").max_client_layout_nodes;
const ClientLayoutNodeType = @import("telar-core").ClientLayoutNode;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LayoutsType = @import("../../workspace/Layouts.zig");
const WorkspaceArrivalType = @import("../WorkspaceArrival.zig");
const WorkspaceSnapshotInput = @import("../../workspace/WorkspaceSnapshotInput.zig");
const max_tabs_per_workspace = @import("telar-core").max_tabs_per_workspace;
const WorkspaceTabInputType = @import("../../workspace/WorkspaceTabInput.zig");
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const PaneAttachmentType = @import("../PaneAttachment.zig");
const types = @import("../types.zig");
const PaneType = @import("../Pane.zig");

test "workspace creation planning requires the attached focused pane" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.planWorkspaceCreation() == null);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    try std.testing.expectEqual(pane_id, model.planWorkspaceCreation().?);
    model.workspace.findPane(pane_id).?.attached = false;
    try std.testing.expect(model.planWorkspaceCreation() == null);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "tab creation planning captures the workspace and attached focused pane" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.planTabCreation() == null);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    try std.testing.expectEqualDeep(TabCreationPlanType{
        .workspace = location.workspace,
        .cwd_source = pane_id,
    }, model.planTabCreation().?);
    model.workspace.findPane(pane_id).?.attached = false;
    try std.testing.expect(model.planTabCreation() == null);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "workspace departure commits one empty version and captures bounded client state" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const active: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const inactive: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const first: PaneIdType = @enumFromInt(1);
    const focused: PaneIdType = @enumFromInt(2);
    const third: PaneIdType = @enumFromInt(3);
    const area: RectType = .{ .w = 40, .h = 10 };
    try model.workspace.bootstrap(.{ .pane_id = first, .location = active, .size = .{ .cols = 20, .rows = 5 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = focused, .location = active, .axis = .horizontal, .area = area });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = third,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(active.tab_id));

    const departure = model.departWorkspace();

    try std.testing.expectEqualDeep(@as(?WorkspaceLocationType, workspace), departure.source);
    try std.testing.expectEqualDeep(active, departure.bookmark.?.location);
    try std.testing.expectEqual(focused, departure.bookmark.?.pane_id);
    try std.testing.expectEqual(focused, departure.bookmark.?.tab_layout.focused().?);
    try std.testing.expectEqualSlices(PaneIdType, &.{ first, focused, third }, departure.panes.slice());
    try std.testing.expect(model.workspace.workspace == null);
    try std.testing.expectEqual(@as(usize, 0), model.workspace.count);
    try std.testing.expectEqualDeep(VersionType{
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(4),
    };
    const left: PaneIdType = @enumFromInt(10);
    const focused: PaneIdType = @enumFromInt(11);
    const area: RectType = .{ .w = 60, .h = 12 };
    var saved: LayoutType = .{};
    try saved.addRoot(left);
    try saved.split(.{ .existing_pane = left, .new_pane = focused, .axis = .horizontal });
    var expected: LayoutSnapshot = .{};
    saved.snapshot(area, &expected);

    const activation = try model.arriveWorkspace(.{
        .pane_id = focused,
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
        .saved_layout = saved,
    });

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expectEqual(focused, model.workspace.activeConst().?.model.layout.focused().?);
    try std.testing.expectEqualDeep(WorkspaceActivationType{
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
    try std.testing.expectEqualDeep(VersionType{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());

    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ left, focused },
    };
    _ = try model.reconcileTab(snapshot, area);
    var actual: LayoutSnapshot = .{};
    model.workspace.activeConst().?.model.layout.snapshot(area, &actual);

    try std.testing.expectEqual(focused, model.workspace.activeConst().?.model.layout.focused().?);
    for ([_]PaneIdType{ left, focused }) |pane_id| {
        try std.testing.expectEqual(expected.find(pane_id).?.outer, actual.find(pane_id).?.outer);
    }
}

test "workspace return restores an inactive tab fullscreen with the requested pane focus" {
    try expectInactiveFullscreenReturn(false);
}

test "workspace creation also retains inactive tab layouts" {
    try expectInactiveFullscreenReturn(true);
}

fn expectInactiveFullscreenReturn(replace: bool) !void {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const other_location: TabLocationType = .{ .workspace = location.workspace, .tab_id = @enumFromInt(2) };
    const first: PaneIdType = @enumFromInt(10);
    const clicked: PaneIdType = @enumFromInt(11);
    const other: PaneIdType = @enumFromInt(20);
    const area: RectType = .{ .w = 101, .h = 41 };
    try model.workspace.bootstrap(.{ .pane_id = first, .location = location, .size = .{ .cols = area.w, .rows = area.h } });
    _ = try model.reconcileTab(.{ .location = location, .panes = &.{first} }, area);
    const original = &model.workspace.active().?.model;
    try original.split(.{ .existing_pane = first, .new_pane = clicked, .location = location, .axis = .vertical, .area = area });
    try std.testing.expect(original.focusPane(first));
    try std.testing.expect(original.resizeFocused(.down, area));
    try std.testing.expect(original.toggleFullscreen());
    var node_storage: [max_client_layout_nodes_module]ClientLayoutNodeType = undefined;
    const expected_nodes = original.layout.clientLayoutNodes(&node_storage);
    _ = try model.workspace.addCreated(.{
        .location = other_location,
        .position = 1,
        .label = "other",
        .root_pane_id = other,
    }, .{ .cols = area.w, .rows = area.h });
    try std.testing.expectEqual(other_location, model.activeTabLocation().?);
    const departure = if (replace)
        (try model.replaceWorkspace(.{
            .pane_id = @enumFromInt(30),
            .location = .{ .workspace = .{ .workspace = @enumFromInt(3) }, .tab_id = @enumFromInt(3) },
            .size = .{ .cols = area.w, .rows = area.h },
        })).departure
    else
        model.departWorkspace();
    try std.testing.expectEqual(other_location, departure.bookmark.?.location);
    if (replace) {
        _ = model.departWorkspace();
    }

    _ = try model.arriveWorkspace(.{ .pane_id = clicked, .location = location, .size = .{ .cols = area.w, .rows = area.h } });
    _ = try model.reconcileTab(.{ .location = location, .panes = &.{ first, clicked } }, area);
    const restored = &model.workspace.active().?.model;
    try std.testing.expect(restored.layout.isFullscreen());
    try std.testing.expectEqual(clicked, restored.layout.focused().?);
    var restored_storage: [max_client_layout_nodes_module]ClientLayoutNodeType = undefined;
    try std.testing.expectEqualDeep(expected_nodes, restored.layout.clientLayoutNodes(&restored_storage));
    try std.testing.expect(restored.contentSize(first, area) == null);
    try std.testing.expectEqual(TerminalSizeType{ .cols = area.w - 2, .rows = area.h - 2 }, restored.contentSize(clicked, area).?);
}

test "rejected workspace arrival preserves its previous model and version" {
    var empty = ModelType.init(std.testing.allocator, true);
    defer empty.deinit();
    const location: TabLocationType = .{
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
    try std.testing.expectEqualDeep(VersionType{}, empty.version());

    var occupied = ModelType.init(std.testing.allocator, true);
    defer occupied.deinit();
    try occupied.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 30, .rows = 8 } });

    try std.testing.expectError(error.ModelNotEmpty, occupied.arriveWorkspace(.{
        .pane_id = @enumFromInt(2),
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqual(@as(usize, 1), occupied.workspace.count);
    try std.testing.expect(occupied.workspace.findPane(@enumFromInt(1)) != null);
    try std.testing.expectEqualDeep(VersionType{}, occupied.version());
}

test "workspace replacement commits the confirmed root and captures retired state" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const previous_workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const previous: TabLocationType = .{
        .workspace = previous_workspace,
        .tab_id = @enumFromInt(1),
    };
    const inactive: TabLocationType = .{
        .workspace = previous_workspace,
        .tab_id = @enumFromInt(2),
    };
    const replacement: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(3),
    };
    const first: PaneIdType = @enumFromInt(1);
    const focused: PaneIdType = @enumFromInt(2);
    const inactive_pane: PaneIdType = @enumFromInt(3);
    const replacement_pane: PaneIdType = @enumFromInt(4);
    try model.workspace.bootstrap(.{ .pane_id = first, .location = previous, .size = .{ .cols = 20, .rows = 5 } });
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

    try std.testing.expectEqualDeep(@as(?WorkspaceLocationType, previous_workspace), committed.departure.source);
    try std.testing.expectEqualDeep(previous, committed.departure.bookmark.?.location);
    try std.testing.expectEqual(focused, committed.departure.bookmark.?.pane_id);
    try std.testing.expectEqualSlices(PaneIdType, &.{ first, focused, inactive_pane }, committed.departure.panes.slice());
    try std.testing.expectEqualDeep(WorkspaceActivationType{
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
    try std.testing.expectEqualDeep(VersionType{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());
}

test "workspace replacement captures invalid copy-mode release" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const previous: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const replacement: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = previous, .size = .{ .cols = 20, .rows = 5 } });
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });

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
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "failed workspace replacement rolls back retained layouts" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const location: TabLocationType = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
    const pane_id: PaneIdType = @enumFromInt(10);
    const area: RectType = .{ .w = 40, .h = 10 };
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = area.w, .rows = area.h } });
    _ = try model.reconcileTab(.{ .location = location, .panes = &.{pane_id} }, area);
    _ = model.togglePaneFullscreen(.{ .area = area }).?;
    const version = model.version();
    const saved_before = model.saved_layouts;
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    model.workspace.gpa = failing.allocator();
    defer model.workspace.gpa = std.testing.allocator;

    try std.testing.expectError(error.OutOfMemory, model.replaceWorkspace(.{
        .pane_id = @enumFromInt(20),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(2) },
        .size = .{ .cols = area.w, .rows = area.h },
    }));
    try std.testing.expectEqualDeep(saved_before, model.saved_layouts);
    try std.testing.expectEqualDeep(version, model.version());
    try std.testing.expectEqual(location, model.activeTabLocation().?);
    try std.testing.expect(model.workspace.active().?.model.layout.isFullscreen());
}

test "provisional arrivals cannot overwrite retained fullscreen layouts" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const location: TabLocationType = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
    const first: PaneIdType = @enumFromInt(10);
    const clicked: PaneIdType = @enumFromInt(11);
    const area: RectType = .{ .w = 60, .h = 12 };
    var saved: LayoutType = .{};
    try saved.addRoot(first);
    try saved.splitFocused(clicked, .vertical);
    try std.testing.expect(saved.focusPane(first));
    try std.testing.expect(saved.toggleFullscreen());
    var layouts: LayoutsType = .{};
    try layouts.remember(.{ .location = location, .pane_id = first, .workspace_active = true, .layout = saved });
    model.restoreClientLayouts(layouts);
    const arrival: WorkspaceArrivalType = .{ .pane_id = clicked, .location = location, .size = .{ .cols = area.w, .rows = area.h } };
    _ = try model.arriveWorkspace(arrival);
    _ = model.departWorkspace();
    try std.testing.expectEqualDeep(saved, model.saved_layouts.find(location).?.layout);

    _ = try model.arriveWorkspace(arrival);
    try std.testing.expectError(error.DuplicatePane, model.reconcileTab(.{ .location = location, .panes = &.{ clicked, clicked } }, area));
    try std.testing.expectEqualDeep(saved, model.saved_layouts.find(location).?.layout);
    _ = try model.reconcileTab(.{ .location = location, .panes = &.{ first, clicked } }, area);
    try std.testing.expect(model.saved_layouts.find(location) == null);
    try std.testing.expect(model.workspace.active().?.model.layout.isFullscreen());
    try std.testing.expectEqual(clicked, model.workspace.active().?.model.layout.focused().?);
    const revision = model.workspace.active().?.model.layout.currentRevision();
    _ = try model.reconcileTab(.{ .location = location, .panes = &.{ first, clicked } }, area);
    try std.testing.expectEqual(revision, model.workspace.active().?.model.layout.currentRevision());
}

test "workspace replacement can recover from an already empty source" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const location: TabLocationType = .{
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
    try std.testing.expectEqualDeep(VersionType{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());
}

test "workspace reconciliation versions semantic dimensions independently" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const first: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    const named: WorkspaceSnapshotInput = .{
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
    try std.testing.expectEqualDeep(VersionType{ .workspace = 1 }, model.version());

    const unchanged = try model.reconcileWorkspace(named);

    try std.testing.expect(!unchanged.workspace_changed);
    try std.testing.expect(!unchanged.tabs_changed);
    try std.testing.expect(!unchanged.active_tab_changed);
    try std.testing.expectEqualDeep(VersionType{ .workspace = 1 }, model.version());

    const reordered: WorkspaceSnapshotInput = .{
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
    try std.testing.expectEqualDeep(VersionType{ .workspace = 1, .tabs = 1 }, model.version());

    const removed: WorkspaceSnapshotInput = .{
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
    try std.testing.expectEqualSlices(TabLocationType, &.{second}, active_change.removed_tabs.slice());
    try std.testing.expectEqualSlices(PaneIdType, &.{@enumFromInt(2)}, active_change.removed_panes.slice());
    try std.testing.expectEqualDeep(VersionType{ .workspace = 1, .tabs = 2, .active_tab = 1 }, model.version());
    try std.testing.expectEqual(model.version().workspace, active_change.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, active_change.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, active_change.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, active_change.panes_revision);
    try std.testing.expectEqual(model.workspace.activeConst().?.snapshot_loaded, active_change.active_snapshot_loaded);
}

test "rejected workspace snapshots preserve state and revisions" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const location: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const empty: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{},
    };

    try std.testing.expectError(error.WorkspaceHasNoTabs, model.reconcileWorkspace(empty));

    const duplicate: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = location.tab_id, .pane_count = 1, .label = "main" },
            .{ .tab_id = location.tab_id, .pane_count = 1, .label = "copy" },
        },
    };
    try std.testing.expectError(error.DuplicateTab, model.reconcileWorkspace(duplicate));

    var excessive_tabs: [max_tabs_per_workspace + 1]WorkspaceTabInputType = undefined;
    for (&excessive_tabs, 0..) |*tab, index| {
        tab.* = .{
            .tab_id = @enumFromInt(@as(u64, @intCast(index + 1))),
            .pane_count = 1,
            .label = "tab",
        };
    }
    const excessive: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &excessive_tabs,
    };
    try std.testing.expectError(error.TabLimitReached, model.reconcileWorkspace(excessive));

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expect(model.workspace.findPane(@enumFromInt(1)) != null);
    try std.testing.expectEqualStrings("", model.workspace.workspaceName());
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "active tab reconciliation versions pane changes and reports retired panes" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: PaneIdType = @enumFromInt(1);
    const second: PaneIdType = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = first, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const discovered: PaneSnapshot = .{
        .location = location,
        .panes = &.{ first, second },
    };

    const addition = try model.reconcileTab(discovered, .{ .w = 40, .h = 10 });

    try std.testing.expect(addition.active);
    try std.testing.expect(addition.panes_changed);
    try std.testing.expectEqual(@as(usize, 0), addition.removed_panes.slice().len);
    try std.testing.expect(model.workspace.findPane(second) != null);
    try std.testing.expectEqualDeep(VersionType{ .panes = 1 }, model.version());
    try std.testing.expectEqualDeep(RectType{ .w = 40, .h = 10 }, addition.area);
    try std.testing.expect(addition.snapshot_loaded);
    try std.testing.expectEqual(model.workspace.activeConst().?.model.layout.currentRevision(), addition.layout_revision);
    try std.testing.expectEqual(model.version().workspace, addition.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, addition.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, addition.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, addition.panes_revision);

    const unchanged = try model.reconcileTab(discovered, .{ .w = 40, .h = 10 });

    try std.testing.expect(!unchanged.panes_changed);
    try std.testing.expectEqualDeep(VersionType{ .panes = 1 }, model.version());

    const removed: PaneSnapshot = .{
        .location = location,
        .panes = &.{second},
    };
    const removal = try model.reconcileTab(removed, .{ .w = 40, .h = 10 });

    try std.testing.expect(removal.panes_changed);
    try std.testing.expectEqualSlices(PaneIdType, &.{first}, removal.removed_panes.slice());
    try std.testing.expect(model.workspace.findPane(first) == null);
    try std.testing.expectEqualDeep(VersionType{ .panes = 2 }, model.version());
}

test "tab reconciliation rejects excessive pane membership atomically" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root_pane: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = root_pane, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    var pane_ids: [max_panes_per_tab_module + 1]PaneIdType = undefined;
    for (&pane_ids, 0..) |*pane_id, index| {
        pane_id.* = @enumFromInt(@as(u64, @intCast(index + 1)));
    }
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &pane_ids,
    };

    try std.testing.expectError(error.TooManyPanes, model.reconcileTab(snapshot, .{ .w = 40, .h = 10 }));

    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(location.tab_id).?.model.pane_count);
    try std.testing.expect(model.workspace.findPane(root_pane) != null);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "inactive tab reconciliation does not advance the visible pane revision" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const active: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const inactive: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = active, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(active.tab_id));
    const snapshot: PaneSnapshot = .{
        .location = inactive,
        .panes = &.{ @enumFromInt(2), @enumFromInt(3) },
    };

    const reconciliation = try model.reconcileTab(snapshot, .{ .w = 40, .h = 10 });

    try std.testing.expect(!reconciliation.active);
    try std.testing.expect(reconciliation.panes_changed);
    try std.testing.expect(model.workspace.findPane(@enumFromInt(3)) != null);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
    try std.testing.expect(reconciliation.snapshot_loaded);
    try std.testing.expectEqual(model.workspace.find(inactive.tab_id).?.model.layout.currentRevision(), reconciliation.layout_revision);
    try std.testing.expectEqual(model.version().panes, reconciliation.panes_revision);
}

test "tab reconciliation rejects pane identities owned by another tab" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const first: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    const snapshot: PaneSnapshot = .{
        .location = first,
        .panes = &.{ @enumFromInt(1), @enumFromInt(2) },
    };

    try std.testing.expectError(error.PaneAlreadyExists, model.reconcileTab(snapshot, .{ .w = 40, .h = 10 }));

    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(first.tab_id).?.model.pane_count);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(second.tab_id).?.model.pane_count);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "pane attachment confirmation changes only active operational state" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const discovered: PaneIdType = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });
    try model.workspace.active().?.model.addDiscovered(.{ .pane_id = discovered, .location = location, .area = .{ .w = 40, .h = 10 } });
    const attachment: PaneAttachmentType = .{ .pane_id = discovered, .location = location };

    try std.testing.expect(model.needsPaneAttachment(attachment));
    try std.testing.expectEqual(types.PaneAttachmentConfirmation.confirmed, try model.confirmPaneAttachment(attachment));
    try std.testing.expect(!model.needsPaneAttachment(attachment));
    try std.testing.expect(model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(VersionType{}, model.version());

    try std.testing.expectEqual(types.PaneAttachmentConfirmation.stale, try model.confirmPaneAttachment(attachment));
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "pane attachment confirmation ignores inactive missing and wrong-location panes" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const first: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const discovered: PaneIdType = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    try model.workspace.active().?.model.addDiscovered(.{ .pane_id = discovered, .location = first, .area = .{ .w = 40, .h = 10 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);

    const inactive: PaneAttachmentType = .{ .pane_id = discovered, .location = first };
    try std.testing.expectEqual(types.PaneAttachmentConfirmation.stale, try model.confirmPaneAttachment(inactive));
    try std.testing.expect(!model.needsPaneAttachment(inactive));
    try std.testing.expect(!model.workspace.findPane(discovered).?.attached);

    try std.testing.expect(model.workspace.select(first.tab_id));
    const missing: PaneAttachmentType = .{ .pane_id = @enumFromInt(9), .location = first };
    const wrong_location: PaneAttachmentType = .{ .pane_id = discovered, .location = second };
    try std.testing.expectEqual(types.PaneAttachmentConfirmation.stale, try model.confirmPaneAttachment(missing));
    try std.testing.expectEqual(types.PaneAttachmentConfirmation.stale, try model.confirmPaneAttachment(wrong_location));
    try std.testing.expect(!model.needsPaneAttachment(missing));
    try std.testing.expect(!model.needsPaneAttachment(wrong_location));
    try std.testing.expect(!model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "tab detachment plans exact operational state before a silent commit" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const first: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const root: PaneIdType = @enumFromInt(1);
    const sibling: PaneIdType = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = first, .size = .{ .cols = 20, .rows = 5 } });
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
    try std.testing.expectEqualDeep(PaneType{ .pane_id = root, .attached = true }, plan.slice()[0]);
    try std.testing.expectEqualDeep(PaneType{ .pane_id = sibling, .attached = false }, plan.slice()[1]);
    try std.testing.expect(plan.owns_paste);
    try std.testing.expect(plan.owns_reported_focus);
    try std.testing.expect(plan.paste_marker_required);
    try std.testing.expect(plan.focus_out_required);

    var invalid = plan;
    invalid.panes[1] = invalid.panes[0];
    try std.testing.expectError(error.InvalidTabDetachment, model.commitTabDetachment(invalid));

    var unbounded = plan;
    unbounded.len = max_panes_per_tab_module + 1;
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
    try std.testing.expectEqualDeep(VersionType{}, model.version());

    try std.testing.expectError(error.UnexpectedTab, model.planTabDetachment(.{
        .workspace = workspace,
        .tab_id = @enumFromInt(9),
    }));
}
