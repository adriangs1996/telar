//! Tab flows over the flat client model: selection, moves, labels, root
//! replacement and snapshot reconciliation.
const core = @import("telar-core");
const std = @import("std");
const icons = @import("../layout/icons.zig");
const Model = @import("../state/Model.zig");
const Change = @import("../types/Change.zig").Change;
const WorkspaceSnapshotInput = @import("WorkspaceSnapshotInput.zig");
const WorkspaceTabInput = @import("WorkspaceTabInput.zig");
const LayoutSnapshot = @import("LayoutSnapshot.zig");
const WorkspaceLayout = @import("WorkspaceLayout.zig");
const PaneSnapshot = @import("PaneSnapshot.zig");
const tab_creation = @import("tab_creation.zig");
const tab_label = @import("tab_label.zig");
const tab_layout = @import("tab_layout.zig");
const tab_move = @import("tab_move.zig");
const tab_rename = @import("tab_rename.zig");
const tab_selection = @import("tab_selection.zig");
const tab_snapshot_reconciliation = @import("tab_snapshot_reconciliation.zig");
const workspace_handoff = @import("workspace_handoff.zig");
const workspace_reconciliation = @import("workspace_reconciliation.zig");
const pane_split = @import("pane_split.zig");

test "selection wraps and moving tabs preserves the active identity" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    _ = try tab_creation.add(&model, .{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(tab_selection.selectOffset(&model, 1));
    try std.testing.expectEqual(@as(core.TabId, @enumFromInt(1)), model.tabs.location[model.tabs.active].tab_id);
    try std.testing.expect(!tab_selection.selectOffset(&model, 0));
    try std.testing.expect(!tab_selection.selectOffset(&model, 2));
    try std.testing.expect(tab_selection.selectOffset(&model, std.math.maxInt(isize)));
    try std.testing.expectEqual(@as(core.TabId, @enumFromInt(2)), model.tabs.location[model.tabs.active].tab_id);
    try std.testing.expect(!tab_selection.selectOffset(&model, std.math.minInt(isize)));
    const original_pane = model.panes.find(@enumFromInt(1)).?;
    try std.testing.expectEqual(Change.changed, try tab_move.move(&model, @enumFromInt(1), 1));
    try std.testing.expectEqual(original_pane, model.panes.find(@enumFromInt(1)).?);
    try std.testing.expectEqual(@as(core.TabId, @enumFromInt(2)), model.tabs.location[model.tabs.active].tab_id);
    try std.testing.expectEqual(Change.unchanged, try tab_move.move(&model, @enumFromInt(1), 1));
    try std.testing.expectError(error.TabNotFound, tab_move.move(&model, @enumFromInt(9), 0));
    try std.testing.expectError(error.InvalidTabPosition, tab_move.move(&model, @enumFromInt(1), 2));
}

test "canonical tab labels distinguish changes and reject invalid values" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    try std.testing.expectEqual(Change.changed, try tab_rename.rename(&model, location.tab_id, "server"));
    try std.testing.expectEqualStrings("server", tab_label.text(&model, model.tabs.active));
    try std.testing.expectEqual(Change.unchanged, try tab_rename.rename(&model, location.tab_id, "server"));
    try std.testing.expectError(error.InvalidTabLabel, tab_rename.rename(&model, location.tab_id, ""));
    try std.testing.expectError(error.InvalidTabLabel, tab_rename.rename(&model, location.tab_id, "bad\nlabel"));
    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, tab_rename.rename(&model, location.tab_id, &invalid_utf8));
    try std.testing.expectError(error.TabNotFound, tab_rename.rename(&model, @enumFromInt(9), "missing"));
    try std.testing.expectEqualStrings("server", tab_label.text(&model, model.tabs.active));
}

test "automatic tab labels follow foreground focus until explicitly renamed" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.PaneId = @enumFromInt(1);
    const second: core.PaneId = @enumFromInt(2);
    try workspace_handoff.bootstrap(&model, .{ .pane_id = first, .location = location, .size = .{ .cols = 40, .rows = 10 } });
    const tab = model.tabs.active;

    try std.testing.expect(tab_label.automatic(&model, tab));
    try std.testing.expectEqualStrings("", model.tabs.canonicalLabel(tab));
    try std.testing.expectEqualStrings("shell", tab_label.text(&model, tab));
    try std.testing.expectEqual(icons.Icon.app_terminal, tab_label.icon(&model, tab).?);

    _ = model.panes.find(first).?.setForegroundName("zsh");
    try std.testing.expectEqualStrings("zsh", tab_label.text(&model, tab));
    _ = model.panes.find(first).?.setForegroundName("nvim");
    try std.testing.expectEqualStrings("nvim", tab_label.text(&model, tab));
    try std.testing.expectEqual(icons.Icon.app_editor, tab_label.icon(&model, tab).?);
    try pane_split.split(&model, tab, .{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    _ = model.panes.find(second).?.setForegroundName("codex");
    try std.testing.expectEqualStrings("codex", tab_label.text(&model, tab));
    try std.testing.expectEqual(icons.Icon.provider_codex, tab_label.icon(&model, tab).?);
    try std.testing.expect(model.tabs.layout[tab].focusPane(first));
    try std.testing.expectEqualStrings("nvim", tab_label.text(&model, tab));

    try std.testing.expectEqual(Change.changed, try tab_rename.rename(&model, location.tab_id, "nvim"));
    try std.testing.expect(!tab_label.automatic(&model, tab));
    try std.testing.expectEqualStrings("nvim", model.tabs.canonicalLabel(tab));
    try std.testing.expect(tab_label.icon(&model, tab) == null);
    _ = model.panes.find(first).?.setForegroundName("git");
    try std.testing.expectEqualStrings("nvim", tab_label.text(&model, tab));
    try std.testing.expect(model.tabs.layout[tab].focusPane(second));
    try std.testing.expectEqualStrings("nvim", tab_label.text(&model, tab));
}

test "automatic and manual tab labels survive canonical workspace snapshots" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabId = @enumFromInt(1);
    const second: core.TabId = @enumFromInt(2);
    const pane: core.PaneId = @enumFromInt(1);
    try workspace_handoff.bootstrap(&model, .{ .pane_id = pane, .location = .{ .workspace = workspace, .tab_id = first }, .size = .{ .cols = 20, .rows = 5 } });
    _ = try tab_creation.add(&model, .{
        .location = .{ .workspace = workspace, .tab_id = second },
        .position = 1,
        .label = "",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(tab_label.automatic(&model, model.tabs.active));
    _ = model.panes.find(pane).?.setForegroundName("claude");
    const snapshot: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first, .pane_count = 1, .label = "" },
            .{ .tab_id = second, .pane_count = 1, .label = "tab 45" },
        },
    };
    try workspace_reconciliation.reconcileTabs(&model, snapshot);
    try workspace_reconciliation.reconcileTabs(&model, snapshot);

    try std.testing.expect(tab_label.automatic(&model, model.tabs.find(first).?));
    try std.testing.expectEqualStrings("claude", tab_label.text(&model, model.tabs.find(first).?));
    try std.testing.expectEqual(icons.Icon.provider_claude, tab_label.icon(&model, model.tabs.find(first).?).?);
    try std.testing.expect(!tab_label.automatic(&model, model.tabs.find(second).?));
    try std.testing.expectEqualStrings("tab 45", tab_label.text(&model, model.tabs.find(second).?));
}

test "failed tab construction does not publish a shifted slot" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    model.gpa = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, tab_creation.add(&model, .{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .position = 0,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 }));

    try std.testing.expectEqual(@as(usize, 1), model.tabs.count);
    try std.testing.expectEqualDeep(first, model.tabs.location[model.tabs.active]);
    try std.testing.expect(model.panes.find(@enumFromInt(2)) == null);
}

test "root replacement constructs before retiring the current workspace" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const previous: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const replacement: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(2),
    };
    const previous_pane: core.PaneId = @enumFromInt(1);
    const replacement_pane: core.PaneId = @enumFromInt(2);
    try workspace_handoff.bootstrap(&model, .{ .pane_id = previous_pane, .location = previous, .size = .{ .cols = 20, .rows = 5 } });
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    model.gpa = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, workspace_handoff.replaceWithRoot(&model, .{
        .pane_id = replacement_pane,
        .location = replacement,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqualDeep(previous, model.tabs.location[model.tabs.active]);
    try std.testing.expect(model.panes.find(previous_pane) != null);
    try std.testing.expect(model.panes.find(replacement_pane) == null);

    model.gpa = std.testing.allocator;
    try workspace_handoff.replaceWithRoot(&model, .{
        .pane_id = replacement_pane,
        .location = replacement,
        .size = .{ .cols = 30, .rows = 8 },
    });

    try std.testing.expectEqual(@as(usize, 1), model.tabs.count);
    try std.testing.expectEqualDeep(replacement, model.tabs.location[model.tabs.active]);
    try std.testing.expect(model.panes.find(previous_pane) == null);
    try std.testing.expect(model.panes.find(replacement_pane) != null);
}

test "displayed workspace name stays canonical when pane cwd changes" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    @memcpy(model.workspace_name[0..5], "telar");
    model.workspace_name_len = 5;

    const tab = model.tabs.active;
    try std.testing.expectEqual(
        true,
        try model.panes.find(@enumFromInt(1)).?.setCwd("/work/telar"),
    );
    try std.testing.expectEqualStrings("telar", model.workspaceName());
    try pane_split.split(&model, tab, .{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = model.tabs.location[tab], .axis = .horizontal, .area = .{ .x = 0, .y = 0, .w = 20, .h = 5 } });
    try std.testing.expectEqual(
        true,
        try model.panes.find(@enumFromInt(2)).?.setCwd("/work/agents/"),
    );
    try std.testing.expect(model.tabs.layout[tab].focusPane(@enumFromInt(2)));
    try std.testing.expectEqualStrings("telar", model.workspaceName());
    try std.testing.expect(model.tabs.layout[tab].focusPane(@enumFromInt(1)));
    try std.testing.expectEqualStrings("telar", model.workspaceName());
}

test "pane gap configuration reaches current and future tabs" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    tab_layout.setPaneGaps(&model, false);
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    try std.testing.expect(!model.tabs.layout[model.tabs.active].pane_gaps);

    const created = try tab_creation.add(&model, .{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(!model.tabs.layout[created].pane_gaps);

    tab_layout.setPaneGaps(&model, true);
    for (model.tabs.layout[0..model.tabs.count]) |layout| {
        try std.testing.expect(layout.pane_gaps);
    }
}

test "pane content size carries the host cell geometry" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    model.host.host_size.cell_width_px = 8;
    model.host.host_size.cell_height_px = 16;
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    const size = tab_layout.contentSize(&model, model.tabs.active, @enumFromInt(1), .{ .w = 20, .h = 5 }).?;
    try std.testing.expectEqual(@as(u16, 8), size.cell_width_px);
    try std.testing.expectEqual(@as(u16, 16), size.cell_height_px);
}

test "workspace snapshots restore labels and order without losing pane layouts" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(7), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    var workspace_name = [_]u8{ 't', 'e', 'l', 'a', 'r' };
    var logs_label = [_]u8{ 'l', 'o', 'g', 's' };
    var main_label = [_]u8{ 'm', 'a', 'i', 'n' };
    const descriptors = [_]WorkspaceTabInput{
        .{ .tab_id = @enumFromInt(2), .pane_count = 1, .label = &logs_label },
        .{ .tab_id = @enumFromInt(1), .pane_count = 1, .label = &main_label },
    };
    const snapshot: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = &workspace_name,
        .tabs = &descriptors,
    };
    try workspace_reconciliation.reconcileTabs(&model, snapshot);
    @memset(&workspace_name, 'x');
    @memset(&logs_label, 'x');
    @memset(&main_label, 'x');

    try std.testing.expectEqualStrings("telar", model.workspaceName());
    try std.testing.expectEqual(@as(core.TabId, @enumFromInt(2)), model.tabs.location[0].tab_id);
    try std.testing.expectEqualStrings("logs", tab_label.text(&model, 0));
    try std.testing.expectEqualStrings("main", tab_label.text(&model, 1));
    try std.testing.expect(model.panes.findIn(@enumFromInt(1), @enumFromInt(7)) != null);
}

test "workspace reconciliation rejects malformed snapshots before mutation" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const root_tab: core.TabId = @enumFromInt(1);
    const root_pane: core.PaneId = @enumFromInt(7);
    try workspace_handoff.bootstrap(&model, .{ .pane_id = root_pane, .location = .{
        .workspace = workspace,
        .tab_id = root_tab,
    }, .size = .{ .cols = 20, .rows = 5 } });

    const empty: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{},
    };
    try std.testing.expectError(error.WorkspaceHasNoTabs, workspace_reconciliation.reconcileTabs(&model, empty));

    var excessive_tabs: [core.max_tabs_per_workspace + 1]WorkspaceTabInput = undefined;
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
    try std.testing.expectError(error.TabLimitReached, workspace_reconciliation.reconcileTabs(&model, excessive));

    const invalid_tab: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{.{ .tab_id = .invalid, .pane_count = 1, .label = "main" }},
    };
    try std.testing.expectError(error.InvalidTabId, workspace_reconciliation.reconcileTabs(&model, invalid_tab));

    const duplicate: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = root_tab, .pane_count = 1, .label = "main" },
            .{ .tab_id = root_tab, .pane_count = 1, .label = "copy" },
        },
    };
    try std.testing.expectError(error.DuplicateTab, workspace_reconciliation.reconcileTabs(&model, duplicate));

    const excessive_panes: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{.{
            .tab_id = root_tab,
            .pane_count = core.max_panes_per_tab + 1,
            .label = "main",
        }},
    };
    try std.testing.expectError(error.TooManyPanes, workspace_reconciliation.reconcileTabs(&model, excessive_panes));

    const invalid_label: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{.{ .tab_id = root_tab, .pane_count = 1, .label = "bad\nlabel" }},
    };
    try std.testing.expectError(error.InvalidTabLabel, workspace_reconciliation.reconcileTabs(&model, invalid_label));

    const invalid_name: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "",
        .tabs = &.{.{ .tab_id = root_tab, .pane_count = 1, .label = "main" }},
    };
    try std.testing.expectError(error.InvalidWorkspaceName, workspace_reconciliation.reconcileTabs(&model, invalid_name));

    const embedded_nul: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "bad\x00name",
        .tabs = &.{.{ .tab_id = root_tab, .pane_count = 1, .label = "main" }},
    };
    try std.testing.expectError(error.InvalidWorkspaceName, workspace_reconciliation.reconcileTabs(&model, embedded_nul));

    const oversized_name: [core.max_workspace_name_bytes + 1]u8 = @splat('x');
    const oversized: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = &oversized_name,
        .tabs = &.{.{ .tab_id = root_tab, .pane_count = 1, .label = "main" }},
    };
    try std.testing.expectError(error.InvalidWorkspaceName, workspace_reconciliation.reconcileTabs(&model, oversized));

    try std.testing.expectEqual(@as(usize, 1), model.tabs.count);
    try std.testing.expectEqual(root_tab, model.tabs.location[model.tabs.active].tab_id);
    try std.testing.expect(model.panes.find(root_pane) != null);
    try std.testing.expectEqualStrings("", model.workspaceName());
}

test "workspace reconciliation replaces a tab at full capacity" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 2, .rows = 1 } });
    for (1..core.max_tabs_per_workspace) |index| {
        const raw_id = index + 1;
        _ = try tab_creation.add(&model, .{
            .location = .{
                .workspace = workspace,
                .tab_id = @enumFromInt(raw_id),
            },
            .position = @intCast(index),
            .label = "tab",
            .root_pane_id = @enumFromInt(raw_id),
        }, .{ .cols = 2, .rows = 1 });
    }

    var descriptors: [core.max_tabs_per_workspace]WorkspaceTabInput = undefined;
    for (&descriptors, 0..) |*descriptor, index| {
        descriptor.* = .{
            .tab_id = @enumFromInt(index + 2),
            .pane_count = 1,
            .label = "tab",
        };
    }
    const snapshot: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &descriptors,
    };

    try workspace_reconciliation.reconcileTabs(&model, snapshot);

    try std.testing.expectEqual(@as(usize, core.max_tabs_per_workspace), model.tabs.count);
    try std.testing.expect(model.tabs.find(@enumFromInt(1)) == null);
    try std.testing.expect(model.tabs.find(@enumFromInt(core.max_tabs_per_workspace + 1)) != null);
    try std.testing.expectEqual(@as(core.TabId, @enumFromInt(core.max_tabs_per_workspace)), model.tabs.location[model.tabs.active].tab_id);
}

test "tab reconciliation preserves the pane selected for workspace restoration" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const restored: core.PaneId = @enumFromInt(42);
    try workspace_handoff.bootstrap(&model, .{ .pane_id = restored, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), restored, @enumFromInt(77) },
    };

    _ = try tab_snapshot_reconciliation.reconcile(&model, snapshot, .{ .w = 60, .h = 12 });
    const restored_tab = model.tabs.active;
    try std.testing.expectEqual(restored, model.tabs.layout[restored_tab].focused().?);
    try std.testing.expectEqual(@as(u16, 1), model.tabs.layout[restored_tab].displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), model.tabs.layout[restored_tab].displayIndex(restored).?);
    try std.testing.expectEqual(@as(u16, 3), model.tabs.layout[restored_tab].displayIndex(@enumFromInt(77)).?);
}

test "initial tab reconciliation replaces a vanished focused pane" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const vanished: core.PaneId = @enumFromInt(10);
    const replacement: core.PaneId = @enumFromInt(42);
    try workspace_handoff.bootstrap(&model, .{ .pane_id = vanished, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{replacement},
    };

    const reconciled = try tab_snapshot_reconciliation.reconcile(&model, snapshot, .{ .w = 60, .h = 12 });

    try std.testing.expect(model.panes.find(vanished) == null);
    try std.testing.expect(model.panes.find(replacement) != null);
    try std.testing.expectEqual(replacement, model.tabs.layout[reconciled].focused().?);
}

test "tab reconciliation rejects duplicate pane membership atomically" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root_pane: core.PaneId = @enumFromInt(10);
    try workspace_handoff.bootstrap(&model, .{ .pane_id = root_pane, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ root_pane, root_pane },
    };

    try std.testing.expectError(error.DuplicatePane, tab_snapshot_reconciliation.reconcile(&model, snapshot, .{ .w = 60, .h = 12 }));

    const tab = model.tabs.find(location.tab_id).?;
    try std.testing.expectEqual(@as(usize, 1), model.panes.countIn(location.tab_id));
    try std.testing.expectEqual(root_pane, model.tabs.layout[tab].focused().?);
    try std.testing.expect(!model.tabs.snapshot_loaded[tab]);
}

test "tab reconciliation restores a bookmarked nested split tree" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const left: core.PaneId = @enumFromInt(10);
    const top_right: core.PaneId = @enumFromInt(42);
    const bottom_right: core.PaneId = @enumFromInt(77);
    const area: core.Rect = .{ .w = 60, .h = 20 };

    var saved: WorkspaceLayout = .{};
    try saved.addRoot(left);
    try saved.split(.{ .existing_pane = left, .new_pane = top_right, .axis = .horizontal });
    try saved.split(.{ .existing_pane = top_right, .new_pane = bottom_right, .axis = .vertical });
    try std.testing.expect(saved.focusPane(left));
    try std.testing.expect(saved.resizeFocused(.right, area));
    try std.testing.expect(saved.focusPane(top_right));
    try std.testing.expect(saved.resizeFocused(.down, area));
    var expected: LayoutSnapshot = .{};
    saved.snapshot(area, &expected);

    try workspace_handoff.bootstrap(&model, .{ .pane_id = top_right, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    model.pending_layout_restore = .{ .location = location, .layout = saved };
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ left, top_right, bottom_right },
    };

    const restored = try tab_snapshot_reconciliation.reconcile(&model, snapshot, area);
    var actual: LayoutSnapshot = .{};
    model.tabs.layout[restored].snapshot(area, &actual);
    for ([_]core.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(expected.find(pane_id).?.outer, actual.find(pane_id).?.outer);
    try std.testing.expectEqual(top_right, model.tabs.layout[restored].focused().?);
}

test "client layout reconciliation restores its saved pane focus" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const left: core.PaneId = @enumFromInt(10);
    const right: core.PaneId = @enumFromInt(42);
    var saved: WorkspaceLayout = .{};
    try saved.addRoot(left);
    try saved.split(.{ .existing_pane = left, .new_pane = right, .axis = .horizontal });
    try std.testing.expect(saved.focusPane(left));

    try workspace_handoff.bootstrap(&model, .{ .pane_id = right, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    model.pending_layout_restore = .{ .location = location, .layout = saved, .restore_saved_focus = true };
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ left, right },
    };

    const restored = try tab_snapshot_reconciliation.reconcile(&model, snapshot, .{ .w = 60, .h = 20 });

    try std.testing.expectEqual(left, model.tabs.layout[restored].focused().?);
}

test "tab reconciliation rejects a bookmarked tree for a changed pane set" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const selected: core.PaneId = @enumFromInt(42);
    var saved: WorkspaceLayout = .{};
    try saved.addRoot(@enumFromInt(10));
    try saved.split(.{ .existing_pane = @enumFromInt(10), .new_pane = selected, .axis = .horizontal });
    try saved.split(.{ .existing_pane = selected, .new_pane = @enumFromInt(77), .axis = .vertical });

    try workspace_handoff.bootstrap(&model, .{ .pane_id = selected, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    model.pending_layout_restore = .{ .location = location, .layout = saved };
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), selected, @enumFromInt(88) },
    };

    const restored = try tab_snapshot_reconciliation.reconcile(&model, snapshot, .{ .w = 60, .h = 20 });
    try std.testing.expectEqual(selected, model.tabs.layout[restored].focused().?);
    try std.testing.expectEqual(@as(u16, 1), model.tabs.layout[restored].displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), model.tabs.layout[restored].displayIndex(selected).?);
    try std.testing.expectEqual(@as(u16, 3), model.tabs.layout[restored].displayIndex(@enumFromInt(88)).?);
}

test "later tab reconciliation preserves the client layout order" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    try workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(10), .location = location, .size = .{ .cols = 30, .rows = 8 } });
    const initial: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), @enumFromInt(42) },
    };
    const tab = try tab_snapshot_reconciliation.reconcile(&model, initial, .{ .w = 60, .h = 12 });
    try pane_split.split(&model, tab, .{ .existing_pane = @enumFromInt(10), .new_pane = @enumFromInt(77), .location = location, .axis = .vertical, .area = .{ .w = 60, .h = 12 } });

    const refresh: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), @enumFromInt(42), @enumFromInt(77) },
    };
    _ = try tab_snapshot_reconciliation.reconcile(&model, refresh, .{ .w = 60, .h = 12 });

    try std.testing.expectEqual(@as(u16, 1), model.tabs.layout[tab].displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), model.tabs.layout[tab].displayIndex(@enumFromInt(77)).?);
    try std.testing.expectEqual(@as(u16, 3), model.tabs.layout[tab].displayIndex(@enumFromInt(42)).?);
}
