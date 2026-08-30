//! Passive semantic state owned by one disposable client.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const Version = struct {
    tabs: u64 = 0,
    active_tab: u64 = 0,
};

pub const Change = enum {
    unchanged,
    changed,
};

pub const TabSelection = struct {
    previous: schema.TabLocation,
    selected: schema.TabLocation,
};

pub const NewTab = struct {
    created: tabs_mod.CreatedTab,
    size: schema.TerminalSize,
};

pub const TabCreation = struct {
    previous: schema.TabLocation,
    created: schema.TabLocation,
};

pub const CloseTab = struct {
    location: schema.TabLocation,
    workspace_closed: bool,
};

pub const ClosedPanes = struct {
    items: [schema.max_panes_per_tab]schema.PaneId = undefined,
    count: u8 = 0,

    fn append(panes: *ClosedPanes, pane_id: schema.PaneId) void {
        std.debug.assert(panes.count < panes.items.len);
        panes.items[panes.count] = pane_id;
        panes.count += 1;
    }

    /// Returns the pane identities captured before their tab was removed.
    ///
    /// ```zig
    /// for (removal.panes.slice()) |pane_id| release(pane_id);
    /// ```
    pub fn slice(panes: *const ClosedPanes) []const schema.PaneId {
        return panes.items[0..panes.count];
    }
};

pub const TabRemoval = struct {
    removed: schema.TabLocation,
    panes: ClosedPanes,
    was_active: bool,
    active: ?schema.TabLocation,
    workspace_closed: bool,
};

pub const Model = struct {
    workspace: tabs_mod.Model,
    tabs_revision: u64 = 0,
    active_tab_revision: u64 = 0,

    /// Creates the semantic model with the configured pane appearance.
    ///
    /// ```zig
    /// var model = Model.init(gpa, true);
    /// ```
    pub fn init(gpa: std.mem.Allocator, pane_gaps: bool) Model {
        var workspace = tabs_mod.Model.init(gpa);
        workspace.setPaneGaps(pane_gaps);

        return .{ .workspace = workspace };
    }

    /// Releases all semantic workspace state owned by the model.
    ///
    /// ```zig
    /// defer model.deinit();
    /// ```
    pub fn deinit(model: *Model) void {
        model.workspace.deinit();
    }

    /// Returns the version that presenters use to observe committed changes.
    ///
    /// ```zig
    /// const before = model.version();
    /// ```
    pub fn version(model: *const Model) Version {
        return .{
            .tabs = model.tabs_revision,
            .active_tab = model.active_tab_revision,
        };
    }

    /// Returns the active tab identity without exposing workspace storage.
    ///
    /// ```zig
    /// const location = model.activeTabLocation() orelse return;
    /// ```
    pub fn activeTabLocation(model: *const Model) ?schema.TabLocation {
        const active = model.workspace.activeConst() orelse return null;

        return active.location;
    }

    /// Commits a runtime-confirmed tab position and advances the model once.
    ///
    /// ```zig
    /// const change = try model.applyTabPosition(location, position);
    /// ```
    pub fn applyTabPosition(model: *Model, location: schema.TabLocation, position: u16) !Change {
        const current_workspace = model.workspace.workspace orelse return error.UnexpectedWorkspace;
        if (!std.meta.eql(current_workspace, location.workspace)) {
            return error.UnexpectedWorkspace;
        }

        const change = try model.workspace.applyPosition(location.tab_id, position);
        if (change == .unchanged) {
            return .unchanged;
        }

        model.tabs_revision +%= 1;
        return .changed;
    }

    /// Commits a runtime-confirmed tab and makes its identity active.
    ///
    /// ```zig
    /// const creation = try model.createTab(command);
    /// ```
    pub fn createTab(model: *Model, command: NewTab) !TabCreation {
        const previous = (model.workspace.activeConst() orelse return error.NoActiveTab).location;

        _ = try model.workspace.addCreated(command.created, command.size);
        model.tabs_revision +%= 1;
        model.active_tab_revision +%= 1;

        return .{
            .previous = previous,
            .created = command.created.location,
        };
    }

    /// Removes a runtime-confirmed tab after validating workspace closure.
    /// Missing tabs return null so lifecycle adapters can remain idempotent.
    ///
    /// ```zig
    /// const removal = try model.closeTab(command) orelse return;
    /// ```
    pub fn closeTab(model: *Model, command: CloseTab) !?TabRemoval {
        const workspace = model.workspace.workspace orelse return null;
        if (!std.meta.eql(workspace, command.location.workspace)) {
            return error.UnexpectedWorkspace;
        }

        const closing = model.workspace.find(command.location.tab_id) orelse return null;
        if (!std.meta.eql(closing.location, command.location)) {
            return error.UnexpectedTab;
        }

        const workspace_closed = model.workspace.count == 1;
        if (workspace_closed != command.workspace_closed) {
            return error.UnexpectedWorkspaceClosure;
        }

        const was_active = model.workspace.active_index ==
            model.workspace.indexOf(command.location.tab_id).?;
        var panes: ClosedPanes = .{};
        var iterator = closing.model.paneIterator();
        while (iterator.next()) |pane| {
            panes.append(pane.id);
        }

        std.debug.assert(model.workspace.remove(command.location.tab_id));
        const active = if (model.workspace.activeConst()) |tab| tab.location else null;
        model.tabs_revision +%= 1;
        if (was_active) {
            model.active_tab_revision +%= 1;
        }

        return .{
            .removed = command.location,
            .panes = panes,
            .was_active = was_active,
            .active = active,
            .workspace_closed = workspace_closed,
        };
    }

    /// Selects one existing tab and returns the committed identity change.
    ///
    /// ```zig
    /// const selection = try model.selectTab(tab_id) orelse return;
    /// ```
    pub fn selectTab(model: *Model, tab_id: schema.TabId) !?TabSelection {
        const previous = model.workspace.activeConst() orelse return error.NoActiveTab;
        const selected_index = model.workspace.indexOf(tab_id) orelse return error.TabNotFound;
        if (selected_index == model.workspace.active_index) {
            return null;
        }

        const selection: TabSelection = .{
            .previous = previous.location,
            .selected = model.workspace.items[selected_index].?.location,
        };
        std.debug.assert(model.workspace.select(tab_id));
        model.active_tab_revision +%= 1;

        return selection;
    }
};

test "tab position commits version semantic changes only" {
    var model = Model.init(std.testing.allocator, true);
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
    try std.testing.expect(model.workspace.select(first.tab_id));

    try std.testing.expectEqual(Change.changed, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);
    try std.testing.expectEqual(first, model.activeTabLocation().?);

    try std.testing.expectEqual(Change.unchanged, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
}

test "rejected tab positions do not advance the model" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });

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
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab creation advances collection and active identity revisions" {
    var model = Model.init(std.testing.allocator, true);
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
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 2), model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "rejected tab creations preserve state and revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
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
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "active tab removal advances collection and active identity revisions" {
    var model = Model.init(std.testing.allocator, true);
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
    try std.testing.expect(model.workspace.select(first.tab_id));

    const removal = (try model.closeTab(.{
        .location = first,
        .workspace_closed = false,
    })).?;

    try std.testing.expectEqualDeep(first, removal.removed);
    try std.testing.expect(removal.was_active);
    try std.testing.expectEqualDeep(second, removal.active.?);
    try std.testing.expectEqualSlices(schema.PaneId, &.{@enumFromInt(1)}, removal.panes.slice());
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "inactive tab removal preserves the active identity revision" {
    var model = Model.init(std.testing.allocator, true);
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
    try std.testing.expect(model.workspace.select(first.tab_id));

    const removal = (try model.closeTab(.{
        .location = second,
        .workspace_closed = false,
    })).?;

    try std.testing.expect(!removal.was_active);
    try std.testing.expectEqualDeep(first, removal.active.?);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);
}

test "workspace closure is validated before the last tab is removed" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectError(error.UnexpectedWorkspaceClosure, model.closeTab(.{
        .location = location,
        .workspace_closed = false,
    }));
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expectEqualDeep(Version{}, model.version());

    const removal = (try model.closeTab(.{
        .location = location,
        .workspace_closed = true,
    })).?;

    try std.testing.expect(removal.workspace_closed);
    try std.testing.expect(removal.was_active);
    try std.testing.expect(removal.active == null);
    try std.testing.expectEqual(@as(usize, 0), model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "tab selection advances only the active identity revision" {
    var model = Model.init(std.testing.allocator, true);
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
    try std.testing.expect(model.workspace.select(first.tab_id));

    const selection = (try model.selectTab(second.tab_id)).?;

    try std.testing.expectEqualDeep(first, selection.previous);
    try std.testing.expectEqualDeep(second, selection.selected);
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 0), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);

    try std.testing.expect((try model.selectTab(second.tab_id)) == null);
    try std.testing.expectError(error.TabNotFound, model.selectTab(@enumFromInt(9)));
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}
