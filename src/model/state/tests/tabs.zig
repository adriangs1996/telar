const icons = @import("../../layout/icons.zig");
const core = @import("telar-core");
const model_data = @import("../../model.zig");
const ClientModel = @import("../ClientModel.zig");
const std = @import("std");
const Version = @import("../Version.zig");
const WorkspaceSnapshotInput = @import("../../workspace/WorkspaceSnapshotInput.zig");

test "fresh workspace snapshots name inactive automatic tabs before pane attachment" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    var name = "codex".*;
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    const snapshot: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "", .foregrounds = &.{.{ .pane_id = @enumFromInt(1), .name = "zsh" }} },
            .{ .tab_id = second.tab_id, .pane_count = 1, .label = "", .foregrounds = &.{.{ .pane_id = @enumFromInt(2), .name = &name }} },
            .{ .tab_id = @enumFromInt(3), .pane_count = 1, .label = "logs", .foregrounds = &.{.{ .pane_id = @enumFromInt(3), .name = "tail" }} },
        },
    };
    _ = try model.reconcileWorkspace(snapshot);
    const inactive = model.tabs.find(second.tab_id).?;
    try std.testing.expectEqualStrings("codex", model_data.tab_label.text(&model, inactive));
    try std.testing.expectEqual(icons.Icon.provider_codex, model_data.tab_label.icon(&model, inactive).?);
    try std.testing.expectEqualStrings("", model.tabs.canonicalLabel(inactive));
    try std.testing.expectEqual(@as(usize, 0), model.panes.countIn(second.tab_id));
    try std.testing.expect(!model.tabs.snapshot_loaded[inactive]);
    try std.testing.expectEqualDeep(first, model.activeTabLocation().?);
    const version = model.version();
    _ = try model.reconcileWorkspace(snapshot);
    try std.testing.expectEqualDeep(version, model.version());
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("codex", model_data.tab_label.text(&model, inactive));

    const changed = (try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = @enumFromInt(2), .name = "claude" } })).?;
    try std.testing.expect(changed.display_changed);
    try std.testing.expectEqualStrings("claude", model_data.tab_label.text(&model, inactive));
    try std.testing.expectEqual(@as(usize, 0), model.panes.countIn(model.tabs.location[inactive].tab_id));
    try std.testing.expect((try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = @enumFromInt(2), .name = "claude" } })) == null);
    try std.testing.expect((try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = @enumFromInt(3), .name = "nvim" } })) == null);
    try std.testing.expectEqualStrings("logs", model_data.tab_label.text(&model, model.tabs.find(@enumFromInt(3)).?));
    try std.testing.expect(model_data.tab_label.icon(&model, model.tabs.find(@enumFromInt(3)).?) == null);

    _ = model.departWorkspace();
    try std.testing.expect((try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = @enumFromInt(2), .name = "git" } })) == null);
}

test "workspace return names inactive tabs using each client's saved pane focus" {
    const model = try std.testing.allocator.create(ClientModel);
    defer std.testing.allocator.destroy(model);
    model.* = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const fresh = try std.testing.allocator.create(ClientModel);
    defer std.testing.allocator.destroy(fresh);
    fresh.* = .init(std.testing.allocator, true);
    defer fresh.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const size: core.TerminalSize = .{ .cols = 40, .rows = 10 };
    const area = core.Rect{ .w = 40, .h = 10 };
    try model_data.workspace_handoff.bootstrap(model, .{ .pane_id = @enumFromInt(1), .location = first, .size = size });
    _ = try model.reconcileTab(.{ .location = first, .panes = &.{@enumFromInt(1)} }, area);
    const inactive = try model_data.tab_creation.add(model, .{ .location = second, .position = 1, .label = "", .root_pane_id = @enumFromInt(2) }, size);
    try model_data.pane_split.split(model, inactive, .{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(3), .location = second, .axis = .horizontal, .area = area });
    _ = try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = @enumFromInt(3), .name = "codex" } });
    try std.testing.expect(model_data.tab_selection.select(model, first.tab_id));
    _ = model.departWorkspace();
    _ = try model.arriveWorkspace(.{ .pane_id = @enumFromInt(1), .location = first, .size = size });
    try model_data.workspace_handoff.bootstrap(fresh, .{ .pane_id = @enumFromInt(1), .location = first, .size = size });
    const snapshot: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "", .foregrounds = &.{.{ .pane_id = @enumFromInt(1), .name = "zsh" }} },
            .{ .tab_id = second.tab_id, .pane_count = 2, .label = "", .foregrounds = &.{
                .{ .pane_id = @enumFromInt(2), .name = "nvim" },
                .{ .pane_id = @enumFromInt(3), .name = "claude" },
            } },
        },
    };
    _ = try model.reconcileWorkspace(snapshot);
    _ = try fresh.reconcileWorkspace(snapshot);
    try std.testing.expectEqualStrings("claude", model_data.tab_label.text(model, model.tabs.find(second.tab_id).?));
    try std.testing.expectEqualStrings("nvim", model_data.tab_label.text(fresh, fresh.tabs.find(second.tab_id).?));
    try std.testing.expectEqual(@as(usize, 0), model.panes.countIn(second.tab_id));
    try std.testing.expectEqual(@as(usize, 0), fresh.panes.countIn(second.tab_id));

    _ = try model.selectTab(.{ .tab_id = second.tab_id });
    _ = try model.reconcileTab(.{ .location = second, .panes = &.{ @enumFromInt(2), @enumFromInt(3) } }, area);
    try std.testing.expectEqualStrings("claude", model_data.tab_label.text(model, model.tabs.find(second.tab_id).?));
    _ = try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = @enumFromInt(3), .name = "git" } });
    try std.testing.expectEqualStrings("git", model_data.tab_label.text(model, model.tabs.find(second.tab_id).?));
}

test "inactive automatic tabs publish foreground changes without changing canonical snapshots" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: core.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const pane: core.PaneId = @enumFromInt(1);
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = pane, .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    const snapshot: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "" },
            .{ .tab_id = second.tab_id, .pane_count = 1, .label = "" },
        },
    };
    _ = try model.reconcileWorkspace(snapshot);
    const before = model.version();

    _ = (try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = pane, .name = "nvim" } })).?;
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqualStrings("nvim", model_data.tab_label.text(&model, model.tabs.find(first.tab_id).?));
    try std.testing.expectEqual(before.pane_foreground + 1, model.version().pane_foreground);
    try std.testing.expectEqual(before.pane_metadata + 1, model.version().pane_metadata);
    const foreground_version = model.version();

    const repeated = try model.reconcileWorkspace(snapshot);
    try std.testing.expect(!repeated.tabs_changed);
    try std.testing.expectEqualDeep(foreground_version, model.version());
    try std.testing.expectEqualStrings("nvim", model_data.tab_label.text(&model, model.tabs.find(first.tab_id).?));
    try std.testing.expect((try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = pane, .name = "nvim" } })) == null);
    try std.testing.expectEqualDeep(foreground_version, model.version());
}

test "tab position commits version semantic changes only" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model_data.tab_selection.select(&model, first.tab_id));

    try std.testing.expectEqual(model_data.Change.changed, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);
    try std.testing.expectEqual(first, model.activeTabLocation().?);

    try std.testing.expectEqual(model_data.Change.unchanged, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
}

test "rejected tab positions do not advance the model" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    const other_workspace: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(error.UnexpectedWorkspace, model.applyTabPosition(other_workspace, 0));
    try std.testing.expectError(error.TabNotFound, model.applyTabPosition(.{
        .workspace = workspace,
        .tab_id = @enumFromInt(9),
    }, 0));
    try std.testing.expectError(error.InvalidTabPosition, model.applyTabPosition(location, 1));
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab rename advances only the collection revision for a semantic change" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model_data.tab_selection.select(&model, first.tab_id));

    try std.testing.expectEqual(model_data.Change.changed, try model.renameTab(.{
        .location = second,
        .label = "server",
    }));
    try std.testing.expectEqualStrings("server", model_data.tab_label.text(&model, model.tabs.find(second.tab_id).?));
    try std.testing.expectEqualDeep(first, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);

    try std.testing.expectEqual(model_data.Change.unchanged, try model.renameTab(.{
        .location = second,
        .label = "server",
    }));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
}

test "rejected tab renames preserve labels and revisions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    try std.testing.expectError(error.UnexpectedWorkspace, model.renameTab(.{
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = location.tab_id,
        },
        .label = "wrong workspace",
    }));
    try std.testing.expectError(error.TabNotFound, model.renameTab(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(9) },
        .label = "missing",
    }));
    try std.testing.expectError(error.InvalidTabLabel, model.renameTab(.{
        .location = location,
        .label = "",
    }));

    try std.testing.expectEqualStrings("shell", model_data.tab_label.text(&model, model.tabs.active));
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab creation advances collection and active identity revisions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });

    const creation = try model.createTab(.{
        .created = .{
            .location = second,
            .position = 0,
            .label = "logs",
            .root_pane_id = @enumFromInt(2),
        },
        .size = .{ .cols = 20, .rows = 5 },
    });

    try std.testing.expectEqualDeep(first, creation.previous);
    try std.testing.expectEqualDeep(second, creation.created);
    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(2)), creation.created_root_pane_id);
    try std.testing.expectEqual(@as(u16, 0), creation.created_position);
    try std.testing.expectEqual(
        model.tabs.layout[model.tabs.find(first.tab_id).?].currentRevision(),
        creation.previous_layout_revision,
    );
    try std.testing.expectEqual(
        model.tabs.layout[model.tabs.find(second.tab_id).?].currentRevision(),
        creation.created_layout_revision,
    );
    try std.testing.expectEqual(@as(u64, 0), creation.tabs_revision_before);
    try std.testing.expectEqual(@as(u64, 0), creation.active_tab_revision_before);
    try std.testing.expectEqual(@as(u64, 0), creation.copy_revision_before);
    try std.testing.expect(!creation.copy_released);
    try std.testing.expectEqual(model.version().workspace, creation.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, creation.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, creation.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, creation.panes_revision);
    try std.testing.expectEqual(model.version().copy, creation.copy_revision);
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 2), model.tabs.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "tab creation captures invalid copy-mode release" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    try std.testing.expect(model.enterCopyMode());
    const version_before = model.version();

    const creation = try model.createTab(.{
        .created = .{
            .location = second,
            .position = 1,
            .label = "logs",
            .root_pane_id = @enumFromInt(2),
        },
        .size = .{ .cols = 20, .rows = 5 },
    });

    try std.testing.expect(creation.copy_released);
    try std.testing.expectEqual(version_before.copy, creation.copy_revision_before);
    try std.testing.expectEqual(version_before.copy +% 1, creation.copy_revision);
    try std.testing.expect(!model.copyModeActive());
}

test "rejected tab creations preserve state and revisions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    const size: core.TerminalSize = .{ .cols = 20, .rows = 5 };

    try std.testing.expectError(error.UnexpectedWorkspace, model.createTab(.{
        .created = .{
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(2) },
                .tab_id = @enumFromInt(2),
            },
            .position = 1,
            .label = "wrong workspace",
            .root_pane_id = @enumFromInt(2),
        },
        .size = size,
    }));
    try std.testing.expectError(error.TabAlreadyExists, model.createTab(.{
        .created = .{
            .location = first,
            .position = 1,
            .label = "duplicate tab",
            .root_pane_id = @enumFromInt(2),
        },
        .size = size,
    }));
    try std.testing.expectError(error.PaneAlreadyExists, model.createTab(.{
        .created = .{
            .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
            .position = 1,
            .label = "duplicate pane",
            .root_pane_id = @enumFromInt(1),
        },
        .size = size,
    }));
    try std.testing.expectError(error.InvalidTabPosition, model.createTab(.{
        .created = .{
            .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
            .position = 2,
            .label = "bad position",
            .root_pane_id = @enumFromInt(2),
        },
        .size = size,
    }));

    try std.testing.expectEqualDeep(first, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 1), model.tabs.count);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "active tab removal advances collection and active identity revisions" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model_data.tab_selection.select(&model, first.tab_id));
    try std.testing.expect(model.enterCopyMode());
    const version_before_removal = model.version();

    const removal = (try model.removeTab(.{
        .location = first,
        .workspace_removed = false,
    })).removed;

    try std.testing.expectEqualDeep(first, removal.removed);
    try std.testing.expect(removal.was_active);
    try std.testing.expectEqualDeep(second, removal.active.?);
    try std.testing.expectEqualSlices(core.PaneId, &.{@enumFromInt(1)}, removal.panes.slice());
    try std.testing.expectEqual(
        model.tabs.layout[model.tabs.active].currentRevision(),
        removal.active_layout_revision,
    );
    try std.testing.expectEqual(@as(u64, 0), removal.active_tab_revision_before);
    try std.testing.expectEqual(model.version().workspace, removal.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, removal.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, removal.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, removal.panes_revision);
    try std.testing.expectEqual(model.version().copy, removal.copy_revision);
    try std.testing.expect(!model.copyModeActive());
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
    try std.testing.expectEqual(version_before_removal.copy +% 1, model.version().copy);
}

test "inactive tab removal preserves the active identity revision" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model_data.tab_selection.select(&model, first.tab_id));

    const removal = (try model.removeTab(.{
        .location = second,
        .workspace_removed = false,
    })).removed;

    try std.testing.expect(!removal.was_active);
    try std.testing.expectEqualDeep(first, removal.active.?);
    try std.testing.expectEqual(
        model.tabs.layout[model.tabs.active].currentRevision(),
        removal.active_layout_revision,
    );
    try std.testing.expectEqual(removal.active_tab_revision_before, removal.active_tab_revision);
    try std.testing.expectEqual(model.version().workspace, removal.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, removal.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, removal.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, removal.panes_revision);
    try std.testing.expectEqual(model.version().copy, removal.copy_revision);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);
}

test "workspace closure is validated before the last tab is removed" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    try std.testing.expectError(error.UnexpectedWorkspaceRemoval, model.removeTab(.{
        .location = location,
        .workspace_removed = false,
    }));
    try std.testing.expectEqual(@as(usize, 1), model.tabs.count);
    try std.testing.expectEqualDeep(Version{}, model.version());

    const removal = (try model.removeTab(.{
        .location = location,
        .workspace_removed = true,
    })).removed;

    try std.testing.expect(removal.workspace_removed);
    try std.testing.expect(removal.was_active);
    try std.testing.expect(removal.active == null);
    try std.testing.expectEqual(@as(u64, 0), removal.active_layout_revision);
    try std.testing.expectEqual(@as(u64, 0), removal.active_tab_revision_before);
    try std.testing.expectEqual(model.version().workspace, removal.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, removal.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, removal.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, removal.panes_revision);
    try std.testing.expectEqual(model.version().copy, removal.copy_revision);
    try std.testing.expectEqual(@as(usize, 0), model.tabs.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "missing tab removal captures exact tab and workspace absence" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const missing: core.TabLocation = .{
        .workspace = location.workspace,
        .tab_id = @enumFromInt(9),
    };

    const missing_tab = try model.removeTab(.{
        .location = missing,
        .workspace_removed = false,
    });

    try std.testing.expect(missing_tab == .stale);
    try std.testing.expectEqualDeep(missing, missing_tab.stale.location);
    try std.testing.expectEqual(model_data.TabRemovalAbsence.tab, missing_tab.stale.absence);
    try std.testing.expectEqual(model.version().workspace, missing_tab.stale.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, missing_tab.stale.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, missing_tab.stale.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, missing_tab.stale.panes_revision);
    try std.testing.expectEqual(model.version().copy, missing_tab.stale.copy_revision);

    const foreign: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = location.tab_id,
    };
    const missing_workspace = try model.removeTab(.{
        .location = foreign,
        .workspace_removed = true,
    });

    try std.testing.expect(missing_workspace == .stale);
    try std.testing.expectEqualDeep(foreign, missing_workspace.stale.location);
    try std.testing.expectEqual(model_data.TabRemovalAbsence.workspace, missing_workspace.stale.absence);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab selection resolves identity position and wrapping offset" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: core.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model_data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model_data.tab_creation.add(&model, .{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model_data.tab_selection.select(&model, first.tab_id));

    const selection = (try model.selectTab(.{ .position = 1 })).?;

    try std.testing.expectEqualDeep(first, selection.previous);
    try std.testing.expectEqualDeep(second, selection.selected);
    try std.testing.expectEqual(
        model.tabs.layout[model.tabs.find(first.tab_id).?].currentRevision(),
        selection.previous_layout_revision,
    );
    try std.testing.expectEqual(
        model.tabs.layout[model.tabs.find(second.tab_id).?].currentRevision(),
        selection.selected_layout_revision,
    );
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 0), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
    try std.testing.expectEqual(model.version().workspace, selection.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, selection.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, selection.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, selection.panes_revision);
    try std.testing.expectEqual(model.version().copy, selection.copy_revision);

    try std.testing.expectEqualDeep(first, (try model.selectTab(.{ .offset = 1 })).?.selected);
    try std.testing.expectEqualDeep(second, (try model.selectTab(.{ .offset = -1 })).?.selected);
    try std.testing.expectEqualDeep(first, (try model.selectTab(.{ .tab_id = first.tab_id })).?.selected);
    try std.testing.expect((try model.selectTab(.{ .tab_id = first.tab_id })) == null);
    try std.testing.expect((try model.selectTab(.{ .position = 9 })) == null);
    try std.testing.expect((try model.selectTab(.{ .offset = 2 })) == null);
    try std.testing.expectError(error.TabNotFound, model.selectTab(.{ .tab_id = @enumFromInt(9) }));
    try std.testing.expectEqual(@as(u64, 4), model.version().active_tab);
}
