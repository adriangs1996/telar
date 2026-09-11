//! Disposable client state for the ordered tabs of one workspace.

const std = @import("std");
const core = @import("telar-core");
const layout_mod = @import("layout_support.zig");
const multiplexer = @import("multiplexer.zig");
pub const ui = core.ui;

pub const schema = core.schema;

pub const max_tabs = schema.max_tabs_per_workspace;

pub const PositionChange = enum {
    unchanged,
    changed,
};

pub const LabelChange = enum {
    unchanged,
    changed,
};

pub fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > schema.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    if (!std.unicode.utf8ValidateSlice(label)) {
        return error.InvalidUtf8;
    }

    for (label) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidTabLabel;
        }
    }
}

pub const CreatedTab = @import("CreatedTab.zig");

pub const WorkspaceTabInput = @import("WorkspaceTabInput.zig");

pub const WorkspaceSnapshotInput = @import("WorkspaceSnapshotInput.zig");

pub const PaneSnapshot = @import("PaneSnapshot.zig");

pub const RootTab = @import("RootTab.zig");

const PendingLayoutRestore = @import("PendingLayoutRestore.zig");

const TabInit = @import("TabInit.zig");

pub const Tab = @import("Tab.zig");

pub const Model = @import("TabsModel.zig");

test "selection wraps and moving tabs preserves the active identity" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    _ = try model.addCreated(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.selectOffset(1));
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(1)), model.activeConst().?.location.tab_id);
    try std.testing.expect(!model.selectOffset(0));
    try std.testing.expect(!model.selectOffset(2));
    try std.testing.expect(model.selectOffset(std.math.maxInt(isize)));
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(2)), model.activeConst().?.location.tab_id);
    try std.testing.expect(!model.selectOffset(std.math.minInt(isize)));
    try std.testing.expectEqual(PositionChange.changed, try model.applyPosition(@enumFromInt(1), 1));
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(2)), model.activeConst().?.location.tab_id);
    try std.testing.expectEqual(PositionChange.unchanged, try model.applyPosition(@enumFromInt(1), 1));
    try std.testing.expectError(error.TabNotFound, model.applyPosition(@enumFromInt(9), 0));
    try std.testing.expectError(error.InvalidTabPosition, model.applyPosition(@enumFromInt(1), 2));
}

test "canonical tab labels distinguish changes and reject invalid values" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.bootstrap(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 20, .rows = 5 } });

    try std.testing.expectEqual(LabelChange.changed, try model.applyLabel(location.tab_id, "server"));
    try std.testing.expectEqualStrings("server", model.activeConst().?.labelSlice());
    try std.testing.expectEqual(LabelChange.unchanged, try model.applyLabel(location.tab_id, "server"));
    try std.testing.expectError(error.InvalidTabLabel, model.applyLabel(location.tab_id, ""));
    try std.testing.expectError(error.InvalidTabLabel, model.applyLabel(location.tab_id, "bad\nlabel"));
    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, model.applyLabel(location.tab_id, &invalid_utf8));
    try std.testing.expectError(error.TabNotFound, model.applyLabel(@enumFromInt(9), "missing"));
    try std.testing.expectEqualStrings("server", model.activeConst().?.labelSlice());
}

test "failed tab construction does not publish a shifted slot" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.bootstrap(.{ .pane_id = @enumFromInt(1), .location = first, .size = .{ .cols = 20, .rows = 5 } });
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    model.gpa = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, model.addCreated(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .position = 0,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 }));

    try std.testing.expectEqual(@as(usize, 1), model.count);
    try std.testing.expectEqualDeep(first, model.activeConst().?.location);
    try std.testing.expect(model.items[1] == null);
}

test "root replacement constructs before retiring the current workspace" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const previous: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const replacement: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(2),
    };
    const previous_pane: schema.PaneId = @enumFromInt(1);
    const replacement_pane: schema.PaneId = @enumFromInt(2);
    try model.bootstrap(.{ .pane_id = previous_pane, .location = previous, .size = .{ .cols = 20, .rows = 5 } });
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    model.gpa = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, model.replaceWithRoot(.{
        .pane_id = replacement_pane,
        .location = replacement,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqualDeep(previous, model.activeConst().?.location);
    try std.testing.expect(model.findPane(previous_pane) != null);
    try std.testing.expect(model.findPane(replacement_pane) == null);

    model.gpa = std.testing.allocator;
    try model.replaceWithRoot(.{
        .pane_id = replacement_pane,
        .location = replacement,
        .size = .{ .cols = 30, .rows = 8 },
    });

    try std.testing.expectEqual(@as(usize, 1), model.count);
    try std.testing.expectEqualDeep(replacement, model.activeConst().?.location);
    try std.testing.expect(model.findPane(previous_pane) == null);
    try std.testing.expect(model.findPane(replacement_pane) != null);
}

test "displayed workspace name stays canonical when pane cwd changes" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    @memcpy(model.workspace_name[0..5], "telar");
    model.workspace_name_len = 5;

    const tab = model.active().?;
    try std.testing.expectEqual(
        multiplexer.MetadataChange.display_changed,
        try tab.model.setPaneCwd(@enumFromInt(1), "/work/telar"),
    );
    try std.testing.expectEqualStrings("telar", model.displayedWorkspaceName());
    try tab.model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = tab.location, .axis = .horizontal, .area = .{ .x = 0, .y = 0, .w = 20, .h = 5 } });
    try std.testing.expectEqual(
        multiplexer.MetadataChange.display_changed,
        try tab.model.setPaneCwd(@enumFromInt(2), "/work/agents/"),
    );
    try std.testing.expect(tab.model.focusPane(@enumFromInt(2)));
    try std.testing.expectEqualStrings("telar", model.displayedWorkspaceName());
    try std.testing.expect(tab.model.focusPane(@enumFromInt(1)));
    try std.testing.expectEqualStrings("telar", model.displayedWorkspaceName());
}

test "pane gap configuration reaches current and future tabs" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.setPaneGaps(false);
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    try std.testing.expect(!model.active().?.model.layout.pane_gaps);

    const created = try model.addCreated(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(!created.model.layout.pane_gaps);

    model.setPaneGaps(true);
    for (model.items[0..model.count]) |slot|
        try std.testing.expect(slot.?.model.layout.pane_gaps);
}

test "host cell geometry reaches current and future tabs" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    model.setCellSize(8, 16);
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    try std.testing.expectEqual(@as(u16, 8), model.active().?.model.cell_width_px);
    try std.testing.expectEqual(@as(u16, 16), model.active().?.model.cell_height_px);

    const created = try model.addCreated(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expectEqual(@as(u16, 8), created.model.cell_width_px);
    try std.testing.expectEqual(@as(u16, 16), created.model.cell_height_px);

    try model.reconcileWorkspace(.{
        .workspace = workspace,
        .name = "work",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .pane_count = 1, .label = "logs" },
            .{ .tab_id = @enumFromInt(3), .pane_count = 0, .label = "empty" },
        },
    });
    const discovered = model.find(@enumFromInt(3)).?;
    try std.testing.expectEqual(@as(u16, 8), discovered.model.cell_width_px);
    try std.testing.expectEqual(@as(u16, 16), discovered.model.cell_height_px);

    model.setCellSize(10, 20);
    for (model.items[0..model.count]) |slot| {
        try std.testing.expectEqual(@as(u16, 10), slot.?.model.cell_width_px);
        try std.testing.expectEqual(@as(u16, 20), slot.?.model.cell_height_px);
    }
}

test "workspace snapshots restore labels and order without losing pane layouts" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(.{ .pane_id = @enumFromInt(7), .location = .{
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
    try model.reconcileWorkspace(snapshot);
    @memset(&workspace_name, 'x');
    @memset(&logs_label, 'x');
    @memset(&main_label, 'x');

    try std.testing.expectEqualStrings("telar", model.workspaceName());
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(2)), model.items[0].?.location.tab_id);
    try std.testing.expectEqualStrings("logs", model.items[0].?.labelSlice());
    try std.testing.expectEqualStrings("main", model.items[1].?.labelSlice());
    try std.testing.expect(model.find(@enumFromInt(1)).?.model.find(@enumFromInt(7)) != null);
}

test "workspace reconciliation rejects malformed snapshots before mutation" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const root_tab: schema.TabId = @enumFromInt(1);
    const root_pane: schema.PaneId = @enumFromInt(7);
    try model.bootstrap(.{ .pane_id = root_pane, .location = .{
        .workspace = workspace,
        .tab_id = root_tab,
    }, .size = .{ .cols = 20, .rows = 5 } });

    const empty: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{},
    };
    try std.testing.expectError(error.WorkspaceHasNoTabs, model.reconcileWorkspace(empty));

    var excessive_tabs: [max_tabs + 1]WorkspaceTabInput = undefined;
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

    const invalid_tab: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{.{ .tab_id = .invalid, .pane_count = 1, .label = "main" }},
    };
    try std.testing.expectError(error.InvalidTabId, model.reconcileWorkspace(invalid_tab));

    const duplicate: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = root_tab, .pane_count = 1, .label = "main" },
            .{ .tab_id = root_tab, .pane_count = 1, .label = "copy" },
        },
    };
    try std.testing.expectError(error.DuplicateTab, model.reconcileWorkspace(duplicate));

    const excessive_panes: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{.{
            .tab_id = root_tab,
            .pane_count = schema.max_panes_per_tab + 1,
            .label = "main",
        }},
    };
    try std.testing.expectError(error.TooManyPanes, model.reconcileWorkspace(excessive_panes));

    const invalid_label: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{.{ .tab_id = root_tab, .pane_count = 1, .label = "" }},
    };
    try std.testing.expectError(error.InvalidTabLabel, model.reconcileWorkspace(invalid_label));

    const invalid_name: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "",
        .tabs = &.{.{ .tab_id = root_tab, .pane_count = 1, .label = "main" }},
    };
    try std.testing.expectError(error.InvalidWorkspaceName, model.reconcileWorkspace(invalid_name));

    const embedded_nul: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = "bad\x00name",
        .tabs = &.{.{ .tab_id = root_tab, .pane_count = 1, .label = "main" }},
    };
    try std.testing.expectError(error.InvalidWorkspaceName, model.reconcileWorkspace(embedded_nul));

    const oversized_name: [schema.max_workspace_name_bytes + 1]u8 = @splat('x');
    const oversized: WorkspaceSnapshotInput = .{
        .workspace = workspace,
        .name = &oversized_name,
        .tabs = &.{.{ .tab_id = root_tab, .pane_count = 1, .label = "main" }},
    };
    try std.testing.expectError(error.InvalidWorkspaceName, model.reconcileWorkspace(oversized));

    try std.testing.expectEqual(@as(usize, 1), model.count);
    try std.testing.expectEqual(root_tab, model.activeConst().?.location.tab_id);
    try std.testing.expect(model.findPane(root_pane) != null);
    try std.testing.expectEqualStrings("", model.workspaceName());
}

test "workspace reconciliation replaces a tab at full capacity" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 2, .rows = 1 } });
    for (1..max_tabs) |index| {
        const raw_id = index + 1;
        _ = try model.addCreated(.{
            .location = .{
                .workspace = workspace,
                .tab_id = @enumFromInt(raw_id),
            },
            .position = @intCast(index),
            .label = "tab",
            .root_pane_id = @enumFromInt(raw_id),
        }, .{ .cols = 2, .rows = 1 });
    }

    var descriptors: [max_tabs]WorkspaceTabInput = undefined;
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

    try model.reconcileWorkspace(snapshot);

    try std.testing.expectEqual(@as(usize, max_tabs), model.count);
    try std.testing.expect(model.find(@enumFromInt(1)) == null);
    try std.testing.expect(model.find(@enumFromInt(max_tabs + 1)) != null);
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(max_tabs)), model.activeConst().?.location.tab_id);
}

test "tab reconciliation preserves the pane selected for workspace restoration" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const restored: schema.PaneId = @enumFromInt(42);
    try model.bootstrap(.{ .pane_id = restored, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), restored, @enumFromInt(77) },
    };

    _ = try model.reconcileTab(snapshot, .{ .w = 60, .h = 12 });
    const restored_model = &model.active().?.model;
    try std.testing.expectEqual(restored, restored_model.layout.focused().?);
    try std.testing.expectEqual(@as(u16, 1), restored_model.displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), restored_model.displayIndex(restored).?);
    try std.testing.expectEqual(@as(u16, 3), restored_model.displayIndex(@enumFromInt(77)).?);
}

test "initial tab reconciliation replaces a vanished focused pane" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const vanished: schema.PaneId = @enumFromInt(10);
    const replacement: schema.PaneId = @enumFromInt(42);
    try model.bootstrap(.{ .pane_id = vanished, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{replacement},
    };

    const reconciled = try model.reconcileTab(snapshot, .{ .w = 60, .h = 12 });

    try std.testing.expect(reconciled.model.find(vanished) == null);
    try std.testing.expect(reconciled.model.find(replacement) != null);
    try std.testing.expectEqual(replacement, reconciled.model.layout.focused().?);
}

test "tab reconciliation rejects duplicate pane membership atomically" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root_pane: schema.PaneId = @enumFromInt(10);
    try model.bootstrap(.{ .pane_id = root_pane, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ root_pane, root_pane },
    };

    try std.testing.expectError(error.DuplicatePane, model.reconcileTab(snapshot, .{ .w = 60, .h = 12 }));

    const tab = model.find(location.tab_id).?;
    try std.testing.expectEqual(@as(usize, 1), tab.model.pane_count);
    try std.testing.expectEqual(root_pane, tab.model.layout.focused().?);
    try std.testing.expect(!tab.snapshot_loaded);
}

test "tab reconciliation restores a bookmarked nested split tree" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const left: schema.PaneId = @enumFromInt(10);
    const top_right: schema.PaneId = @enumFromInt(42);
    const bottom_right: schema.PaneId = @enumFromInt(77);
    const area: ui.Rect = .{ .w = 60, .h = 20 };

    var saved: layout_mod.Layout = .{};
    try saved.addRoot(left);
    try saved.split(.{ .existing_pane = left, .new_pane = top_right, .axis = .horizontal });
    try saved.split(.{ .existing_pane = top_right, .new_pane = bottom_right, .axis = .vertical });
    try std.testing.expect(saved.focusPane(left));
    try std.testing.expect(saved.resizeFocused(.right, area));
    try std.testing.expect(saved.focusPane(top_right));
    try std.testing.expect(saved.resizeFocused(.down, area));
    var expected: layout_mod.Snapshot = .{};
    saved.snapshot(area, &expected);

    try model.bootstrap(.{ .pane_id = top_right, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    try std.testing.expect(model.restoreLayoutOnNextSnapshot(location, saved));
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ left, top_right, bottom_right },
    };

    const restored = try model.reconcileTab(snapshot, area);
    var actual: layout_mod.Snapshot = .{};
    restored.model.layout.snapshot(area, &actual);
    for ([_]schema.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(expected.find(pane_id).?.outer, actual.find(pane_id).?.outer);
    try std.testing.expectEqual(top_right, restored.model.layout.focused().?);
}

test "client layout reconciliation restores its saved pane focus" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const left: schema.PaneId = @enumFromInt(10);
    const right: schema.PaneId = @enumFromInt(42);
    var saved: layout_mod.Layout = .{};
    try saved.addRoot(left);
    try saved.split(.{ .existing_pane = left, .new_pane = right, .axis = .horizontal });
    try std.testing.expect(saved.focusPane(left));

    try model.bootstrap(.{ .pane_id = right, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    try std.testing.expect(model.restoreClientLayoutOnNextSnapshot(location, saved));
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ left, right },
    };

    const restored = try model.reconcileTab(snapshot, .{ .w = 60, .h = 20 });

    try std.testing.expectEqual(left, restored.model.layout.focused().?);
}

test "tab reconciliation rejects a bookmarked tree for a changed pane set" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const selected: schema.PaneId = @enumFromInt(42);
    var saved: layout_mod.Layout = .{};
    try saved.addRoot(@enumFromInt(10));
    try saved.split(.{ .existing_pane = @enumFromInt(10), .new_pane = selected, .axis = .horizontal });
    try saved.split(.{ .existing_pane = selected, .new_pane = @enumFromInt(77), .axis = .vertical });

    try model.bootstrap(.{ .pane_id = selected, .location = location, .size = .{ .cols = 30, .rows = 8 } });
    try std.testing.expect(model.restoreLayoutOnNextSnapshot(location, saved));
    const snapshot: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), selected, @enumFromInt(88) },
    };

    const restored = try model.reconcileTab(snapshot, .{ .w = 60, .h = 20 });
    try std.testing.expectEqual(selected, restored.model.layout.focused().?);
    try std.testing.expectEqual(@as(u16, 1), restored.model.displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), restored.model.displayIndex(selected).?);
    try std.testing.expectEqual(@as(u16, 3), restored.model.displayIndex(@enumFromInt(88)).?);
}

test "later tab reconciliation preserves the client layout order" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    try model.bootstrap(.{ .pane_id = @enumFromInt(10), .location = location, .size = .{ .cols = 30, .rows = 8 } });
    const initial: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), @enumFromInt(42) },
    };
    const tab = try model.reconcileTab(initial, .{ .w = 60, .h = 12 });
    try tab.model.split(.{ .existing_pane = @enumFromInt(10), .new_pane = @enumFromInt(77), .location = location, .axis = .vertical, .area = .{ .w = 60, .h = 12 } });

    const refresh: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), @enumFromInt(42), @enumFromInt(77) },
    };
    _ = try model.reconcileTab(refresh, .{ .w = 60, .h = 12 });

    try std.testing.expectEqual(@as(u16, 1), tab.model.displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), tab.model.displayIndex(@enumFromInt(77)).?);
    try std.testing.expectEqual(@as(u16, 3), tab.model.displayIndex(@enumFromInt(42)).?);
}
