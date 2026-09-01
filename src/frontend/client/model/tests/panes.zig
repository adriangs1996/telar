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

test "pane focus resolves identity and direction through one visible revision" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 80, .h = 24 };
    try model.workspace.bootstrap(first, location, .{ .cols = 80, .rows = 24 });
    try model.workspace.active().?.model.split(first, second, location, .horizontal, area);

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

    try std.testing.expect(model.workspace.active().?.model.toggleFullscreen());
    const identified = model.focusPane(.{
        .target = .{ .pane_id = second },
        .area = area,
    }).?;

    try std.testing.expectEqual(first, identified.previous);
    try std.testing.expectEqual(second, identified.focused);
    try std.testing.expect(identified.geometry_changed);
    try std.testing.expectEqual(@as(u64, 2), identified.panes_revision);
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
    try std.testing.expectEqual(client_model.Version{ .panes = 2 }, model.version());
}

test "pane resize owns direction resolution geometry and visible revisions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 101, .h = 41 };
    try model.workspace.bootstrap(first, location, .{ .cols = 101, .rows = 41 });
    const active = &model.workspace.active().?.model;
    try active.split(first, second, location, .horizontal, area);
    try std.testing.expect(active.focusPane(first));
    const width_before = active.contentSize(first, area).?.cols;

    const resized = model.resizePane(.{ .direction = .right, .area = area }).?;

    try std.testing.expectEqualDeep(location, resized.location);
    try std.testing.expectEqual(first, resized.focused);
    try std.testing.expectEqual(model.version().panes, resized.panes_revision);
    try std.testing.expectEqualDeep(area, resized.area);
    try std.testing.expect(!resized.fullscreen);
    try std.testing.expect(active.contentSize(first, area).?.cols > width_before);
    try std.testing.expectEqual(client_model.Version{ .panes = 1 }, model.version());
    try std.testing.expect((model.resizePane(.{ .direction = .up, .area = area })) == null);
    try std.testing.expectEqual(client_model.Version{ .panes = 1 }, model.version());

    try std.testing.expect(active.toggleFullscreen());
    const fullscreen_resize = model.resizePane(.{ .direction = .left, .area = area }).?;
    try std.testing.expect(active.layout.isFullscreen());
    try std.testing.expectEqual(model.version().panes, fullscreen_resize.panes_revision);
    try std.testing.expect(fullscreen_resize.fullscreen);
    try std.testing.expectEqual(client_model.Version{ .panes = 2 }, model.version());
    try std.testing.expect(active.toggleFullscreen());
    try std.testing.expectEqual(width_before, active.contentSize(first, area).?.cols);

    while (model.resizePane(.{ .direction = .right, .area = .{ .w = 7, .h = 3 } }) != null) {}
    const version_at_limit = model.version();
    try std.testing.expect((model.resizePane(.{
        .direction = .right,
        .area = .{ .w = 7, .h = 3 },
    })) == null);
    try std.testing.expectEqualDeep(version_at_limit, model.version());

    model.workspace.deinit();
    try std.testing.expect((model.resizePane(.{ .direction = .right, .area = area })) == null);
    try std.testing.expectEqualDeep(version_at_limit, model.version());
}

test "pane fullscreen preserves tiled geometry through two visible revisions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 101, .h = 41 };
    try model.workspace.bootstrap(first, location, .{ .cols = 101, .rows = 41 });
    const active = &model.workspace.active().?.model;
    try std.testing.expect(model.togglePaneFullscreen(.{ .area = area }) == null);
    try std.testing.expectEqual(client_model.Version{}, model.version());
    try active.split(first, second, location, .horizontal, area);
    try std.testing.expect(active.focusPane(first));
    const first_tiled = active.contentSize(first, area).?;
    const second_tiled = active.contentSize(second, area).?;

    const entered = model.togglePaneFullscreen(.{ .area = area }).?;

    try std.testing.expectEqualDeep(location, entered.location);
    try std.testing.expectEqual(first, entered.focused);
    try std.testing.expectEqual(model.version().panes, entered.panes_revision);
    try std.testing.expectEqualDeep(area, entered.area);
    try std.testing.expect(entered.fullscreen);
    try std.testing.expectEqual(schema.TerminalSize{ .cols = area.w, .rows = area.h }, active.contentSize(first, area).?);
    try std.testing.expect(active.contentSize(second, area) == null);
    try std.testing.expectEqual(client_model.Version{ .panes = 1 }, model.version());

    const exited = model.togglePaneFullscreen(.{ .area = area }).?;

    try std.testing.expect(!exited.fullscreen);
    try std.testing.expectEqual(first_tiled, active.contentSize(first, area).?);
    try std.testing.expectEqual(second_tiled, active.contentSize(second, area).?);
    try std.testing.expectEqual(client_model.Version{ .panes = 2 }, model.version());

    model.workspace.deinit();
    try std.testing.expect(model.togglePaneFullscreen(.{ .area = area }) == null);
    try std.testing.expectEqual(client_model.Version{ .panes = 2 }, model.version());
}

test "pane closure planning requires the active attached pane without mutation" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    const closure = model.planPaneClosure().?;

    try std.testing.expectEqual(pane_id, closure.pane_id);
    try std.testing.expectEqualDeep(location, closure.location);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());

    model.workspace.findPane(pane_id).?.attached = false;

    try std.testing.expect(model.planPaneClosure() == null);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "active pane retirement advances the visible pane revision once" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(first, location, .{ .cols = 40, .rows = 10 });
    try model.workspace.active().?.model.split(
        first,
        second,
        location,
        .horizontal,
        .{ .w = 40, .h = 10 },
    );

    const retirement = model.retirePane(second);

    try std.testing.expect(retirement == .retired);
    try std.testing.expectEqual(second, retirement.retired.pane_id);
    try std.testing.expectEqualDeep(location, retirement.retired.location);
    try std.testing.expect(retirement.retired.active);
    try std.testing.expect(!retirement.retired.tab_empty);
    try std.testing.expectEqual(
        model.workspace.activeConst().?.model.layout.currentRevision(),
        retirement.retired.layout_revision,
    );
    try std.testing.expectEqual(model.version().workspace, retirement.retired.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, retirement.retired.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, retirement.retired.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, retirement.retired.panes_revision);
    try std.testing.expect(model.workspace.findPane(second) == null);
    try std.testing.expectEqual(first, model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 1 }, model.version());

    const repeated = model.retirePane(second);

    try std.testing.expect(repeated == .stale);
    try std.testing.expectEqual(second, repeated.stale.pane_id);
    try std.testing.expectEqual(model.version().workspace, repeated.stale.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, repeated.stale.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, repeated.stale.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, repeated.stale.panes_revision);
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 1 }, model.version());
}

test "inactive pane retirement changes membership without a visible revision" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const inactive: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const inactive_pane: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(@enumFromInt(1), active, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(active.tab_id));

    const retirement = model.retirePane(inactive_pane);

    try std.testing.expect(retirement == .retired);
    try std.testing.expect(!retirement.retired.active);
    try std.testing.expect(retirement.retired.tab_empty);
    try std.testing.expectEqual(
        model.workspace.find(inactive.tab_id).?.model.layout.currentRevision(),
        retirement.retired.layout_revision,
    );
    try std.testing.expectEqual(model.version().workspace, retirement.retired.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, retirement.retired.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, retirement.retired.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, retirement.retired.panes_revision);
    try std.testing.expect(model.workspace.findPane(inactive_pane) == null);
    try std.testing.expectEqualDeep(active, model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "split confirmation replaces a target retired during pane creation" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const target: schema.PaneId = @enumFromInt(1);
    const created: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(target, location, .{ .cols = 40, .rows = 10 });
    try std.testing.expect(model.workspace.active().?.model.removePane(target));

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = location,
            .axis = .horizontal,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(client_model.PaneSplitDisposition.active, commit.disposition);
    try std.testing.expectEqual(client_model.Change.changed, commit.change);
    try std.testing.expect(model.workspace.findPane(target) == null);
    try std.testing.expect(model.workspace.findPane(created).?.attached);
    try std.testing.expectEqual(created, model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 1 }, model.version());
    try std.testing.expectEqualDeep(ui.Rect{ .w = 40, .h = 10 }, commit.area);
    try std.testing.expectEqual(model.workspace.activeConst().?.model.layout.currentRevision(), commit.layout_revision);
    try std.testing.expectEqual(model.version().workspace, commit.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, commit.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, commit.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, commit.panes_revision);
}

test "inactive split confirmation retains membership without visible revision" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const target: schema.PaneId = @enumFromInt(1);
    const created: schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(target, first, .{ .cols = 40, .rows = 10 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 40, .rows = 10 });
    tabs_mod.Model.detachAll(model.workspace.find(first.tab_id).?);

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = first,
            .axis = .vertical,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(client_model.PaneSplitDisposition.inactive, commit.disposition);
    try std.testing.expectEqual(client_model.Change.unchanged, commit.change);
    try std.testing.expect(!model.workspace.findPane(created).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
    try std.testing.expectEqual(model.workspace.find(first.tab_id).?.model.layout.currentRevision(), commit.layout_revision);
    try std.testing.expectEqual(model.version().panes, commit.panes_revision);
    try std.testing.expect(model.recoverPaneSplit(.{
        .split = commitSplit(target, first, .vertical),
        .area = .{ .w = 40, .h = 10 },
    }) == .not_required);
}

test "split confirmation leaves a retired tab unrepresented" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const target: schema.PaneId = @enumFromInt(1);
    const created: schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(target, first, .{ .cols = 40, .rows = 10 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 40, .rows = 10 });
    try std.testing.expect(model.workspace.remove(first.tab_id));

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = first,
            .axis = .horizontal,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(client_model.PaneSplitDisposition.stale, commit.disposition);
    try std.testing.expectEqual(client_model.Change.unchanged, commit.change);
    try std.testing.expect(model.workspace.findPane(created) == null);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
    try std.testing.expectEqual(@as(u64, 0), commit.layout_revision);
    try std.testing.expectEqual(model.version().workspace, commit.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, commit.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, commit.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, commit.panes_revision);
}

fn commitSplit(target: schema.PaneId, location: schema.TabLocation, axis: layout_mod.Axis) client_model.PaneSplit {
    return .{
        .target_pane = target,
        .location = location,
        .axis = axis,
        .area = .{ .w = 40, .h = 10 },
    };
}
