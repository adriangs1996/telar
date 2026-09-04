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

test "tab position commits version semantic changes only" {
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
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    try std.testing.expectEqual(client_model.Change.changed, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);
    try std.testing.expectEqual(first, model.activeTabLocation().?);

    try std.testing.expectEqual(client_model.Change.unchanged, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
}

test "rejected tab positions do not advance the model" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    const other_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(error.UnexpectedWorkspace, model.applyTabPosition(other_workspace, 0));
    try std.testing.expectError(error.TabNotFound, model.applyTabPosition(.{
        .workspace = workspace,
        .tab_id = @enumFromInt(9),
    }, 0));
    try std.testing.expectError(error.InvalidTabPosition, model.applyTabPosition(location, 1));
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "tab rename advances only the collection revision for a semantic change" {
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
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    try std.testing.expectEqual(client_model.Change.changed, try model.renameTab(.{
        .location = second,
        .label = "server",
    }));
    try std.testing.expectEqualStrings("server", model.workspace.find(second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(first, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);

    try std.testing.expectEqual(client_model.Change.unchanged, try model.renameTab(.{
        .location = second,
        .label = "server",
    }));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
}

test "rejected tab renames preserve labels and revisions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

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

    try std.testing.expectEqualStrings("main", model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "tab creation advances collection and active identity revisions" {
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
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });

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
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(2)), creation.created_root_pane_id);
    try std.testing.expectEqual(@as(u16, 0), creation.created_position);
    try std.testing.expectEqual(
        model.workspace.find(first.tab_id).?.model.layout.currentRevision(),
        creation.previous_layout_revision,
    );
    try std.testing.expectEqual(
        model.workspace.find(second.tab_id).?.model.layout.currentRevision(),
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
    try std.testing.expectEqual(@as(usize, 2), model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "tab creation captures invalid copy-mode release" {
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
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
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
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    const size: schema.TerminalSize = .{ .cols = 20, .rows = 5 };

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
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "active tab removal advances collection and active identity revisions" {
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
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));
    try std.testing.expect(model.enterCopyMode());
    const version_before_removal = model.version();

    const removal = (try model.removeTab(.{
        .location = first,
        .workspace_removed = false,
    })).removed;

    try std.testing.expectEqualDeep(first, removal.removed);
    try std.testing.expect(removal.was_active);
    try std.testing.expectEqualDeep(second, removal.active.?);
    try std.testing.expectEqualSlices(schema.PaneId, &.{@enumFromInt(1)}, removal.panes.slice());
    try std.testing.expectEqual(
        model.workspace.activeConst().?.model.layout.currentRevision(),
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
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    const removal = (try model.removeTab(.{
        .location = second,
        .workspace_removed = false,
    })).removed;

    try std.testing.expect(!removal.was_active);
    try std.testing.expectEqualDeep(first, removal.active.?);
    try std.testing.expectEqual(
        model.workspace.activeConst().?.model.layout.currentRevision(),
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
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    try std.testing.expectError(error.UnexpectedWorkspaceRemoval, model.removeTab(.{
        .location = location,
        .workspace_removed = false,
    }));
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());

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
    try std.testing.expectEqual(@as(usize, 0), model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "missing tab removal captures exact tab and workspace absence" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const missing: schema.TabLocation = .{
        .workspace = location.workspace,
        .tab_id = @enumFromInt(9),
    };

    const missing_tab = try model.removeTab(.{
        .location = missing,
        .workspace_removed = false,
    });

    try std.testing.expect(missing_tab == .stale);
    try std.testing.expectEqualDeep(missing, missing_tab.stale.location);
    try std.testing.expectEqual(client_model.TabRemovalAbsence.tab, missing_tab.stale.absence);
    try std.testing.expectEqual(model.version().workspace, missing_tab.stale.workspace_revision);
    try std.testing.expectEqual(model.version().tabs, missing_tab.stale.tabs_revision);
    try std.testing.expectEqual(model.version().active_tab, missing_tab.stale.active_tab_revision);
    try std.testing.expectEqual(model.version().panes, missing_tab.stale.panes_revision);
    try std.testing.expectEqual(model.version().copy, missing_tab.stale.copy_revision);

    const foreign: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = location.tab_id,
    };
    const missing_workspace = try model.removeTab(.{
        .location = foreign,
        .workspace_removed = true,
    });

    try std.testing.expect(missing_workspace == .stale);
    try std.testing.expectEqualDeep(foreign, missing_workspace.stale.location);
    try std.testing.expectEqual(client_model.TabRemovalAbsence.workspace, missing_workspace.stale.absence);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "tab selection resolves identity position and wrapping offset" {
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
    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    const selection = (try model.selectTab(.{ .position = 1 })).?;

    try std.testing.expectEqualDeep(first, selection.previous);
    try std.testing.expectEqualDeep(second, selection.selected);
    try std.testing.expectEqual(
        model.workspace.find(first.tab_id).?.model.layout.currentRevision(),
        selection.previous_layout_revision,
    );
    try std.testing.expectEqual(
        model.workspace.find(second.tab_id).?.model.layout.currentRevision(),
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
