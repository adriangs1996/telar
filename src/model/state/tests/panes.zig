const core = @import("telar-core");
const model_data = @import("../../model.zig");
const ClientModel = @import("../ClientModel.zig");
const std = @import("std");
const VersionType = @import("../Version.zig");

test "pane focus resolves identity and direction through one visible revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    const area: core.Rect = .{ .w = 80, .h = 24 };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = 80, .rows = 24 } });
    try model_data.pane_split.split(&model, model.tabs.active, .{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    _ = model.panes.find(first).?.setForegroundName("nvim");
    _ = model.panes.find(second).?.setForegroundName("codex");
    try std.testing.expectEqualStrings("codex", model_data.tab_label.text(&model, model.tabs.active));

    const directional = model.focusPane(.{
        .target = .{ .direction = .left },
        .area = area,
    }).?;

    try std.testing.expectEqualDeep(location, directional.location);
    try std.testing.expectEqual(second, directional.previous);
    try std.testing.expectEqual(first, directional.focused);
    try std.testing.expect(!directional.geometry_changed);
    try std.testing.expectEqual(@as(u64, 1), directional.panes_revision);
    try std.testing.expectEqual(@as(u64, 1), model.version().panes);
    try std.testing.expectEqualStrings("nvim", model_data.tab_label.text(&model, model.tabs.active));

    try std.testing.expect(model.tabs.layout[model.tabs.active].toggleFullscreen());
    const identified = model.focusPane(.{
        .target = .{ .pane_id = second },
        .area = area,
    }).?;

    try std.testing.expectEqual(first, identified.previous);
    try std.testing.expectEqual(second, identified.focused);
    try std.testing.expect(identified.geometry_changed);
    try std.testing.expectEqual(@as(u64, 2), identified.panes_revision);
    try std.testing.expectEqualStrings("codex", model_data.tab_label.text(&model, model.tabs.active));
    try std.testing.expect((model.focusPane(.{
        .target = .{ .pane_id = second },
        .area = area,
    })) == null);
    try std.testing.expect((model.focusPane(.{
        .target = .{ .pane_id = @enumFromInt(9) },
        .area = area,
    })) == null);
    try std.testing.expect((model.focusPane(.{
        .target = .{ .direction = .right },
        .area = area,
    })) == null);
    try std.testing.expectEqual(VersionType{ .panes = 2 }, model.version());
}

test "fullscreen directional focus publishes geometry only for horizontal moves" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    const area: core.Rect = .{ .w = 80, .h = 24 };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = 80, .rows = 24 } });
    try model_data.pane_split.split(&model, model.tabs.active, .{ .existing_pane = first, .new_pane = second, .location = location, .axis = .vertical, .area = area });
    try std.testing.expect(model.tabs.layout[model.tabs.active].focusPane(first));
    const tiled_size = model_data.tab_layout.contentSize(&model, model.tabs.active, second, area).?;
    _ = model.togglePaneFullscreen(.{ .area = area }).?;
    const entered_version = model.version();
    for ([_]model_data.LayoutDirection{
        .up,
        .down,
        .left,
    }) |direction| {
        try std.testing.expect(model.focusPane(.{ .target = .{ .direction = direction }, .area = area }) == null);
    }

    try std.testing.expectEqualDeep(entered_version, model.version());
    const moved = model.focusPane(.{ .target = .{ .direction = .right }, .area = area }).?;
    try std.testing.expectEqual(first, moved.previous);
    try std.testing.expectEqual(second, moved.focused);
    try std.testing.expect(moved.geometry_changed);
    try std.testing.expectEqual(entered_version.panes + 1, moved.panes_revision);
    try std.testing.expectEqual(core.TerminalSize{ .cols = 78, .rows = 22 }, model_data.tab_layout.contentSize(&model, model.tabs.active, second, area).?);
    try std.testing.expect(model_data.tab_layout.contentSize(&model, model.tabs.active, first, area) == null);
    try std.testing.expect(model.focusPane(.{ .target = .{ .direction = .right }, .area = area }) == null);
    try std.testing.expectEqual(moved.panes_revision, model.version().panes);

    const exited = model.togglePaneFullscreen(.{ .area = area }).?;
    try std.testing.expectEqual(second, exited.focused);
    try std.testing.expectEqual(tiled_size, model_data.tab_layout.contentSize(&model, model.tabs.active, second, area).?);
    const spatial = model.focusPane(.{ .target = .{ .direction = .up }, .area = area }).?;
    try std.testing.expectEqual(first, spatial.focused);
    try std.testing.expect(!spatial.geometry_changed);
}

test "pane resize owns direction resolution geometry and visible revisions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    const area: core.Rect = .{ .w = 101, .h = 41 };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = 101, .rows = 41 } });
    try model_data.pane_split.split(&model, model.tabs.active, .{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    try std.testing.expect(model.tabs.layout[model.tabs.active].focusPane(first));
    const width_before = model_data.tab_layout.contentSize(&model, model.tabs.active, first, area).?.cols;

    const resized = model.resizePane(.{ .direction = .right, .area = area }).?;

    try std.testing.expectEqualDeep(location, resized.location);
    try std.testing.expectEqual(first, resized.focused);
    try std.testing.expectEqual(model.version().panes, resized.panes_revision);
    try std.testing.expectEqualDeep(area, resized.area);
    try std.testing.expect(!resized.fullscreen);
    try std.testing.expect(model_data.tab_layout.contentSize(&model, model.tabs.active, first, area).?.cols > width_before);
    try std.testing.expectEqual(VersionType{ .panes = 1 }, model.version());
    try std.testing.expect((model.resizePane(.{ .direction = .up, .area = area })) == null);
    try std.testing.expectEqual(VersionType{ .panes = 1 }, model.version());

    try std.testing.expect(model.tabs.layout[model.tabs.active].toggleFullscreen());
    const fullscreen_resize = model.resizePane(.{ .direction = .left, .area = area }).?;
    try std.testing.expect(model.tabs.layout[model.tabs.active].isFullscreen());
    try std.testing.expectEqual(model.version().panes, fullscreen_resize.panes_revision);
    try std.testing.expect(fullscreen_resize.fullscreen);
    try std.testing.expectEqual(VersionType{ .panes = 2 }, model.version());
    try std.testing.expect(model.tabs.layout[model.tabs.active].toggleFullscreen());
    try std.testing.expectEqual(width_before, model_data.tab_layout.contentSize(&model, model.tabs.active, first, area).?.cols);

    while (model.resizePane(.{ .direction = .right, .area = .{ .w = 7, .h = 3 } }) != null) {}
    const version_at_limit = model.version();
    try std.testing.expect((model.resizePane(.{
        .direction = .right,
        .area = .{ .w = 7, .h = 3 },
    })) == null);
    try std.testing.expectEqualDeep(version_at_limit, model.version());

    model_data.workspace_handoff.clear(&model);
    try std.testing.expect((model.resizePane(.{ .direction = .right, .area = area })) == null);
    try std.testing.expectEqualDeep(version_at_limit, model.version());
}

test "pane fullscreen preserves tiled geometry through two visible revisions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    const area: core.Rect = .{ .w = 101, .h = 41 };
    try std.testing.expect(model.togglePaneFullscreen(.{ .area = area }) == null);
    try std.testing.expectEqual(VersionType{}, model.version());
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = 101, .rows = 41 } });
    try model_data.pane_split.split(&model, model.tabs.active, .{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    try std.testing.expect(model.tabs.layout[model.tabs.active].focusPane(first));
    const first_tiled = model_data.tab_layout.contentSize(&model, model.tabs.active, first, area).?;
    const second_tiled = model_data.tab_layout.contentSize(&model, model.tabs.active, second, area).?;

    const entered = model.togglePaneFullscreen(.{ .area = area }).?;

    try std.testing.expectEqualDeep(location, entered.location);
    try std.testing.expectEqual(first, entered.focused);
    try std.testing.expectEqual(model.version().panes, entered.panes_revision);
    try std.testing.expectEqualDeep(area, entered.area);
    try std.testing.expect(entered.fullscreen);
    try std.testing.expectEqual(core.TerminalSize{ .cols = area.w - 2, .rows = area.h - 2 }, model_data.tab_layout.contentSize(&model, model.tabs.active, first, area).?);
    try std.testing.expect(model_data.tab_layout.contentSize(&model, model.tabs.active, second, area) == null);
    try std.testing.expectEqual(VersionType{ .panes = 1 }, model.version());

    const exited = model.togglePaneFullscreen(.{ .area = area }).?;

    try std.testing.expect(!exited.fullscreen);
    try std.testing.expectEqual(first_tiled, model_data.tab_layout.contentSize(&model, model.tabs.active, first, area).?);
    try std.testing.expectEqual(second_tiled, model_data.tab_layout.contentSize(&model, model.tabs.active, second, area).?);
    try std.testing.expectEqual(VersionType{ .panes = 2 }, model.version());

    model_data.workspace_handoff.clear(&model);
    try std.testing.expect(model.togglePaneFullscreen(.{ .area = area }) == null);
    try std.testing.expectEqual(VersionType{ .panes = 2 }, model.version());
}

test "splitting a single fullscreen pane focuses the new pane without leaving fullscreen" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    const area: core.Rect = .{ .w = 101, .h = 41 };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = area.w, .rows = area.h } });
    const entered = model.togglePaneFullscreen(.{ .area = area }).?;
    try std.testing.expect(entered.fullscreen);
    const plan = model.planPaneSplit(.{ .axis = .vertical, .area = area }).?;
    const commit = try model.commitPaneSplit(.{ .split = plan.split, .new_pane = second });
    try std.testing.expectEqual(.active, commit.disposition);
    try std.testing.expect(model.tabs.layout[model.tabs.active].isFullscreen());
    try std.testing.expectEqual(second, model.tabs.layout[model.tabs.active].focused().?);
    try std.testing.expect(model_data.tab_layout.contentSize(&model, model.tabs.active, first, area) == null);
    try std.testing.expectEqual(plan.restore_resize.size, model_data.tab_layout.contentSize(&model, model.tabs.active, second, area).?);

    const moved = model.focusPane(.{ .target = .{ .direction = .left }, .area = area }).?;
    try std.testing.expectEqual(first, moved.focused);
    try std.testing.expect(moved.geometry_changed);
    try std.testing.expect(model.focusPane(.{ .target = .{ .direction = .down }, .area = area }) == null);
    const exited = model.togglePaneFullscreen(.{ .area = area }).?;
    try std.testing.expect(!exited.fullscreen);
    try std.testing.expect(model_data.tab_layout.contentSize(&model, model.tabs.active, first, area) != null);
    try std.testing.expect(model_data.tab_layout.contentSize(&model, model.tabs.active, second, area) != null);
    try std.testing.expectEqual(second, model.focusPane(.{ .target = .{ .direction = .down }, .area = area }).?.focused);
}

test "pane closure planning requires the active attached pane without mutation" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });

    const closure = model.planPaneClosure().?;

    try std.testing.expectEqual(pane_id, closure.pane_id);
    try std.testing.expectEqualDeep(location, closure.location);
    try std.testing.expectEqualDeep(VersionType{}, model.version());

    model.panes.find(pane_id).?.attached = false;

    try std.testing.expect(model.planPaneClosure() == null);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "active pane retirement advances the visible pane revision once" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = 40, .rows = 10 } });
    try model_data.pane_split.split(&model, model.tabs.active, .{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });

    const retirement = model.retirePane(second);

    try std.testing.expect(retirement == .retired);
    try std.testing.expectEqual(second, retirement.retired.pane_id);
    try std.testing.expectEqualDeep(location, retirement.retired.location);
    try std.testing.expect(retirement.retired.active);
    try std.testing.expect(!retirement.retired.tab_empty);
    try std.testing.expectEqual(
        model.tabs.layout[model.tabs.active].currentRevision(),
        retirement.retired.layout_revision,
    );
    try std.testing.expectEqual(model.version().workspace, retirement.retired.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, retirement.retired.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, retirement.retired.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, retirement.retired.panes_revision);
    try std.testing.expect(model.panes.find(second) == null);
    try std.testing.expectEqual(first, model.tabs.layout[model.tabs.active].focused().?);
    try std.testing.expectEqualDeep(VersionType{ .panes = 1 }, model.version());

    const repeated = model.retirePane(second);

    try std.testing.expect(repeated == .stale);
    try std.testing.expectEqual(second, repeated.stale.pane_id);
    try std.testing.expectEqual(model.version().workspace, repeated.stale.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, repeated.stale.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, repeated.stale.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, repeated.stale.panes_revision);
    try std.testing.expectEqualDeep(VersionType{ .panes = 1 }, model.version());
}

test "inactive pane retirement changes membership without a visible revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const inactive: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const inactive_pane: core.PaneId = @enumFromInt(2);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = active, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model_data.tab_selection.select(&model, active.tab_id));

    const retirement = model.retirePane(inactive_pane);

    try std.testing.expect(retirement == .retired);
    try std.testing.expect(!retirement.retired.active);
    try std.testing.expect(retirement.retired.tab_empty);
    try std.testing.expectEqual(
        model.tabs.layout[model.tabs.find(inactive.tab_id).?].currentRevision(),
        retirement.retired.layout_revision,
    );
    try std.testing.expectEqual(model.version().workspace, retirement.retired.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, retirement.retired.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, retirement.retired.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, retirement.retired.panes_revision);
    try std.testing.expect(model.panes.find(inactive_pane) == null);
    try std.testing.expectEqualDeep(active, model.activeTabLocation().?);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "split confirmation replaces a target retired during pane creation" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const target: core.PaneId = @enumFromInt(1);
    const created: core.PaneId = @enumFromInt(2);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = target, .location = location, .size = .{ .cols = 40, .rows = 10 } });
    try std.testing.expect(model_data.tab_layout.removePane(&model, target));

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = location,
            .axis = .horizontal,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(model_data.PaneSplitDisposition.active, commit.disposition);
    try std.testing.expectEqual(model_data.Change.changed, commit.change);
    try std.testing.expect(model.panes.find(target) == null);
    try std.testing.expect(model.panes.find(created).?.attached);
    try std.testing.expectEqual(created, model.tabs.layout[model.tabs.active].focused().?);
    try std.testing.expectEqualDeep(VersionType{ .panes = 1 }, model.version());
    try std.testing.expectEqualDeep(core.Rect{ .w = 40, .h = 10 }, commit.area);
    try std.testing.expectEqual(model.tabs.layout[model.tabs.active].currentRevision(), commit.layout_revision);
    try std.testing.expectEqual(model.version().workspace, commit.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, commit.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, commit.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, commit.panes_revision);
}

test "inactive split confirmation retains membership without visible revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const target: core.PaneId = @enumFromInt(1);
    const created: core.PaneId = @enumFromInt(3);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = target, .location = first, .size = .{ .cols = 40, .rows = 10 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 40, .rows = 10 });
    var detached = model.panes.iterate(first.tab_id);
    while (detached.next()) |pane| {
        pane.attached = false;
        pane.pending_frame_id = 0;
    }

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = first,
            .axis = .vertical,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(model_data.PaneSplitDisposition.inactive, commit.disposition);
    try std.testing.expectEqual(model_data.Change.unchanged, commit.change);
    try std.testing.expect(!model.panes.find(created).?.attached);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
    try std.testing.expectEqual(model.tabs.layout[model.tabs.find(first.tab_id).?].currentRevision(), commit.layout_revision);
    try std.testing.expectEqual(model.version().panes, commit.panes_revision);
    try std.testing.expect(model.recoverPaneSplit(.{
        .split = commitSplit(target, first, .vertical),
        .area = .{ .w = 40, .h = 10 },
    }) == .not_required);
}

test "split confirmation leaves a retired tab unrepresented" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const target: core.PaneId = @enumFromInt(1);
    const created: core.PaneId = @enumFromInt(3);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = target, .location = first, .size = .{ .cols = 40, .rows = 10 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 40, .rows = 10 });
    try std.testing.expect(model_data.tab_removal.remove(&model, first.tab_id));

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = first,
            .axis = .horizontal,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(model_data.PaneSplitDisposition.stale, commit.disposition);
    try std.testing.expectEqual(model_data.Change.unchanged, commit.change);
    try std.testing.expect(model.panes.find(created) == null);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
    try std.testing.expectEqual(@as(u64, 0), commit.layout_revision);
    try std.testing.expectEqual(model.version().workspace, commit.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, commit.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, commit.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, commit.panes_revision);
}

fn commitSplit(target: core.PaneId, location: core.TabLocation, axis: model_data.LayoutAxis) model_data.PaneSplit {
    return .{
        .target_pane = target,
        .location = location,
        .axis = axis,
        .area = .{ .w = 40, .h = 10 },
    };
}

test "applying layouts rejects foreign membership before changing focus or geometry" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    const area: core.Rect = .{ .w = 80, .h = 24 };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = 80, .rows = 24 } });
    try model_data.pane_split.split(&model, model.tabs.active, .{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    const saved = model.tabs.layout[model.tabs.active];
    const before = model.version();
    try std.testing.expectError(error.LayoutPaneMismatch, model.applyPaneLayout(.{ .location = location, .layout = saved, .panes = .{ .ids = &.{ first, @enumFromInt(99) }, .focused = first }, .area = area }));
    try std.testing.expectEqualDeep(before, model.version());
    try std.testing.expectEqual(second, model.tabs.layout[model.tabs.active].focused().?);
    const change = try model.applyPaneLayout(.{ .location = location, .layout = saved, .panes = .{ .ids = &.{ first, second }, .focused = first }, .area = area });
    try std.testing.expectEqual(first, change.focused);
    try std.testing.expect(change.geometry_changed);
    try std.testing.expectEqual(before.panes + 1, model.version().panes);
}
