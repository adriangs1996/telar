//! Disposable client state for the ordered tabs of one workspace.

const std = @import("std");
const core = @import("telar-core");
const layout_mod = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");
const ui = core.ui;

const schema = core.schema;

pub const max_tabs = schema.max_tabs_per_workspace;

const PendingLayoutRestore = struct {
    location: schema.TabLocation,
    layout: layout_mod.Layout,
};

pub const Tab = struct {
    location: schema.TabLocation,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    label_len: u8 = 0,
    model: multiplexer.Model,
    snapshot_loaded: bool = false,
    restore_display_order: bool = false,

    fn init(
        gpa: std.mem.Allocator,
        location: schema.TabLocation,
        label: []const u8,
        pane_gaps: bool,
    ) Tab {
        var tab: Tab = .{
            .location = location,
            .model = .init(gpa),
        };
        tab.model.setPaneGaps(pane_gaps);
        tab.setLabel(label);
        return tab;
    }

    fn deinit(tab: *Tab) void {
        tab.model.deinit();
    }

    pub fn labelSlice(tab: *const Tab) []const u8 {
        return tab.label[0..tab.label_len];
    }

    fn setLabel(tab: *Tab, label: []const u8) void {
        std.debug.assert(label.len != 0 and label.len <= tab.label.len);
        @memcpy(tab.label[0..label.len], label);
        tab.label_len = @intCast(label.len);
    }
};

pub const Model = struct {
    gpa: std.mem.Allocator,
    workspace: ?schema.WorkspaceLocation = null,
    workspace_name: [schema.max_workspace_name_bytes]u8 = undefined,
    workspace_name_len: u16 = 0,
    items: [max_tabs]?Tab = [_]?Tab{null} ** max_tabs,
    count: usize = 0,
    active_index: usize = 0,
    pane_gaps: bool = true,
    pending_layout_restore: ?PendingLayoutRestore = null,

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(model: *Model) void {
        for (&model.items) |*slot| {
            if (slot.*) |*tab| tab.deinit();
            slot.* = null;
        }
        model.count = 0;
        model.workspace = null;
        model.workspace_name_len = 0;
        model.pending_layout_restore = null;
    }

    pub fn setPaneGaps(model: *Model, enabled: bool) void {
        if (model.pane_gaps == enabled) return;
        model.pane_gaps = enabled;
        for (model.items[0..model.count]) |*slot|
            if (slot.*) |*tab| tab.model.setPaneGaps(enabled);
    }

    pub fn bootstrap(
        model: *Model,
        pane_id: schema.PaneId,
        location: schema.TabLocation,
        size: schema.TerminalSize,
    ) !void {
        if (model.count != 0) return error.ModelNotEmpty;
        var tab = Tab.init(model.gpa, location, "main", model.pane_gaps);
        errdefer tab.deinit();
        try tab.model.addRoot(pane_id, location, size);
        tab.restore_display_order = true;
        model.items[0] = tab;
        model.count = 1;
        model.active_index = 0;
        model.workspace = location.workspace;
    }

    pub fn restoreLayoutOnNextSnapshot(
        model: *Model,
        location: schema.TabLocation,
        saved: layout_mod.Layout,
    ) bool {
        if (model.find(location.tab_id) == null) return false;
        model.pending_layout_restore = .{ .location = location, .layout = saved };
        return true;
    }

    /// Iterates the open tabs in order without exposing the slot array.
    pub const TabIterator = struct {
        items: []?Tab,
        index: usize = 0,

        pub fn next(iterator: *TabIterator) ?*Tab {
            while (iterator.index < iterator.items.len) {
                const slot = &iterator.items[iterator.index];
                iterator.index += 1;
                if (slot.*) |*tab| return tab;
            }
            return null;
        }
    };

    pub fn tabIterator(model: *Model) TabIterator {
        return .{ .items = model.items[0..model.count] };
    }

    pub fn active(model: *Model) ?*Tab {
        if (model.count == 0) return null;
        return &model.items[model.active_index].?;
    }

    pub fn activeConst(model: *const Model) ?*const Tab {
        if (model.count == 0) return null;
        return &model.items[model.active_index].?;
    }

    pub fn activeIndex(model: *const Model) ?usize {
        return if (model.count == 0) null else model.active_index;
    }

    pub fn workspaceName(model: *const Model) []const u8 {
        return model.workspace_name[0..model.workspace_name_len];
    }

    pub fn displayedWorkspaceName(model: *const Model) []const u8 {
        return model.workspaceName();
    }

    pub fn find(model: *Model, tab_id: schema.TabId) ?*Tab {
        for (model.items[0..model.count]) |*slot| {
            const tab = if (slot.*) |*value| value else continue;
            if (tab.location.tab_id == tab_id) return tab;
        }
        return null;
    }

    pub fn indexOf(model: *const Model, tab_id: schema.TabId) ?usize {
        for (model.items[0..model.count], 0..) |slot, index|
            if (slot != null and slot.?.location.tab_id == tab_id) return index;
        return null;
    }

    pub fn findPane(model: *Model, pane_id: schema.PaneId) ?*multiplexer.Pane {
        for (model.items[0..model.count]) |*slot| {
            const tab = if (slot.*) |*value| value else continue;
            if (tab.model.find(pane_id)) |pane| return pane;
        }
        return null;
    }

    pub fn detachAll(tab: *Tab) void {
        for (&tab.model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            pane.attached = false;
            pane.pending_frame_id = 0;
        }
    }

    pub fn reconcileTab(
        model: *Model,
        snapshot: schema.TabSnapshotView,
        area: ui.Rect,
    ) !*Tab {
        const tab = model.find(snapshot.location.tab_id) orelse return error.UnexpectedTab;
        if (!std.meta.eql(tab.location, snapshot.location)) return error.UnexpectedTab;
        const focused_before = tab.model.layout.focused();
        var seen: [multiplexer.max_panes]schema.PaneId = undefined;
        var seen_count: usize = 0;
        var iterator = snapshot.panes();
        while (try iterator.next()) |descriptor| {
            seen[seen_count] = descriptor.pane_id;
            seen_count += 1;
            if (tab.model.find(descriptor.pane_id) == null)
                try tab.model.addDiscovered(descriptor.pane_id, snapshot.location, area);
        }
        var removed: [multiplexer.max_panes]schema.PaneId = undefined;
        var removed_count: usize = 0;
        for (&tab.model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            if (std.mem.findScalar(schema.PaneId, seen[0..seen_count], pane.id) == null) {
                removed[removed_count] = pane.id;
                removed_count += 1;
            }
        }
        for (removed[0..removed_count]) |pane_id| _ = tab.model.removePane(pane_id);
        if (focused_before) |pane_id| {
            const restored_layout = if (model.pending_layout_restore) |pending|
                std.meta.eql(pending.location, snapshot.location) and
                    tab.model.restoreSavedLayout(pending.layout, seen[0..seen_count], pane_id)
            else
                false;
            if (model.pending_layout_restore) |pending| {
                if (std.meta.eql(pending.location, snapshot.location))
                    model.pending_layout_restore = null;
            }
            if (!restored_layout) {
                if (tab.restore_display_order)
                    try tab.model.restoreDisplayOrder(seen[0..seen_count], pane_id)
                else
                    _ = tab.model.focusPane(pane_id);
            }
        }
        tab.restore_display_order = false;
        tab.snapshot_loaded = true;
        tab.model.composition_invalidated = true;
        return tab;
    }

    pub fn tabForPane(model: *Model, pane_id: schema.PaneId) ?*Tab {
        for (model.items[0..model.count]) |*slot| {
            const tab = if (slot.*) |*value| value else continue;
            if (tab.model.find(pane_id) != null) return tab;
        }
        return null;
    }

    pub fn reconcileWorkspace(model: *Model, snapshot: schema.WorkspaceSnapshotView) !void {
        if (model.workspace == null or !std.meta.eql(model.workspace.?, snapshot.workspace))
            return error.UnexpectedWorkspace;

        @memcpy(model.workspace_name[0..snapshot.name.len], snapshot.name);
        model.workspace_name_len = @intCast(snapshot.name.len);

        const active_id = model.activeConst().?.location.tab_id;
        var iterator = snapshot.tabs();
        var index: usize = 0;
        while (try iterator.next()) |descriptor| : (index += 1) {
            if (model.indexOf(descriptor.tab_id)) |existing_index| {
                if (existing_index != index)
                    std.mem.swap(?Tab, &model.items[existing_index], &model.items[index]);
                const existing = &model.items[index].?;
                existing.setLabel(descriptor.label);
                if (existing.model.pane_count != descriptor.pane_count)
                    existing.snapshot_loaded = false;
            } else {
                if (model.count == max_tabs) return error.TabLimitReached;
                var cursor = model.count;
                while (cursor > index) : (cursor -= 1)
                    model.items[cursor] = model.items[cursor - 1];
                model.items[index] = Tab.init(model.gpa, .{
                    .workspace = snapshot.workspace,
                    .tab_id = descriptor.tab_id,
                }, descriptor.label, model.pane_gaps);
                model.count += 1;
            }
        }
        while (model.count > index) {
            model.count -= 1;
            model.items[model.count].?.deinit();
            model.items[model.count] = null;
        }
        model.active_index = model.indexOf(active_id) orelse 0;
    }

    pub fn addCreated(
        model: *Model,
        created: schema.TabCreated,
        size: schema.TerminalSize,
    ) !*Tab {
        if (model.count == max_tabs or created.position > model.count)
            return error.TabLimitReached;
        var cursor = model.count;
        while (cursor > created.position) : (cursor -= 1)
            model.items[cursor] = model.items[cursor - 1];
        var tab = Tab.init(model.gpa, created.location, created.label, model.pane_gaps);
        errdefer tab.deinit();
        try tab.model.addRoot(created.root_pane_id, created.location, size);
        tab.snapshot_loaded = true;
        model.items[created.position] = tab;
        model.count += 1;
        model.active_index = created.position;
        return &model.items[created.position].?;
    }

    pub fn rename(model: *Model, tab_id: schema.TabId, label: []const u8) bool {
        const tab = model.find(tab_id) orelse return false;
        tab.setLabel(label);
        return true;
    }

    pub fn select(model: *Model, tab_id: schema.TabId) bool {
        const index = model.indexOf(tab_id) orelse return false;
        if (index == model.active_index) return false;
        model.active_index = index;
        return true;
    }

    pub fn selectOffset(model: *Model, offset: isize) bool {
        if (model.count < 2) return false;
        const count: isize = @intCast(model.count);
        const current: isize = @intCast(model.active_index);
        model.active_index = @intCast(@mod(current + offset, count));
        return true;
    }

    pub fn selectPosition(model: *Model, position: usize) bool {
        if (position >= model.count or position == model.active_index) return false;
        model.active_index = position;
        return true;
    }

    pub fn move(model: *Model, tab_id: schema.TabId, position: usize) bool {
        const from = model.indexOf(tab_id) orelse return false;
        if (position >= model.count) return false;
        const active_id = model.activeConst().?.location.tab_id;
        if (from < position) {
            var index = from;
            while (index < position) : (index += 1)
                std.mem.swap(?Tab, &model.items[index], &model.items[index + 1]);
        } else {
            var index = from;
            while (index > position) : (index -= 1)
                std.mem.swap(?Tab, &model.items[index], &model.items[index - 1]);
        }
        model.active_index = model.indexOf(active_id).?;
        return from != position;
    }

    pub fn remove(model: *Model, tab_id: schema.TabId) bool {
        const index = model.indexOf(tab_id) orelse return false;
        const active_id = model.activeConst().?.location.tab_id;
        model.items[index].?.deinit();
        var cursor = index;
        while (cursor + 1 < model.count) : (cursor += 1)
            model.items[cursor] = model.items[cursor + 1];
        model.count -= 1;
        model.items[model.count] = null;
        if (model.count == 0) {
            model.active_index = 0;
            model.workspace = null;
            model.workspace_name_len = 0;
            return true;
        }
        model.active_index = model.indexOf(active_id) orelse @min(index, model.count - 1);
        return true;
    }
};

test "selection wraps and moving tabs preserves the active identity" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
    _ = try model.addCreated(.{
        .request_id = @enumFromInt(2),
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.selectOffset(1));
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(1)), model.activeConst().?.location.tab_id);
    try std.testing.expect(model.move(@enumFromInt(1), 1));
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(1)), model.activeConst().?.location.tab_id);
}

test "displayed workspace name stays canonical when pane cwd changes" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
    @memcpy(model.workspace_name[0..5], "telar");
    model.workspace_name_len = 5;

    const tab = model.active().?;
    try std.testing.expect(try tab.model.find(@enumFromInt(1)).?.setCwd("/work/telar"));
    try std.testing.expectEqualStrings("telar", model.displayedWorkspaceName());
    try tab.model.split(
        @enumFromInt(1),
        @enumFromInt(2),
        tab.location,
        .horizontal,
        .{ .x = 0, .y = 0, .w = 20, .h = 5 },
    );
    try std.testing.expect(try tab.model.find(@enumFromInt(2)).?.setCwd("/work/agents/"));
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
    try model.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(!model.active().?.model.layout.pane_gaps);

    const created = try model.addCreated(.{
        .request_id = @enumFromInt(2),
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

test "workspace snapshots restore labels and order without losing pane layouts" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try model.bootstrap(@enumFromInt(7), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
    const descriptors = [_]schema.TabDescriptor{
        .{ .tab_id = @enumFromInt(2), .position = 0, .pane_count = 1, .label = "logs" },
        .{ .tab_id = @enumFromInt(1), .position = 1, .pane_count = 1, .label = "main" },
    };
    var buffer: [1024]u8 = undefined;
    const decoded = (try schema.decodeServer(try schema.encodeWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(4),
        .workspace = workspace,
        .name = "telar",
        .tabs = &descriptors,
    }))).workspace_snapshot;
    try model.reconcileWorkspace(decoded);

    try std.testing.expectEqualStrings("telar", model.workspaceName());
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(2)), model.items[0].?.location.tab_id);
    try std.testing.expectEqualStrings("logs", model.items[0].?.labelSlice());
    try std.testing.expect(model.find(@enumFromInt(1)).?.model.find(@enumFromInt(7)) != null);
}

test "tab reconciliation preserves the pane selected for workspace restoration" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    const restored: schema.PaneId = @enumFromInt(42);
    try model.bootstrap(restored, location, .{ .cols = 30, .rows = 8 });
    var buffer: [512]u8 = undefined;
    const snapshot = (try schema.decodeServer(try schema.encodeTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(3),
        .location = location,
        .panes = &.{
            .{ .pane_id = @enumFromInt(10), .lifecycle = .running },
            .{ .pane_id = restored, .lifecycle = .running },
            .{ .pane_id = @enumFromInt(77), .lifecycle = .running },
        },
    }))).tab_snapshot;

    _ = try model.reconcileTab(snapshot, .{ .w = 60, .h = 12 });
    const restored_model = &model.active().?.model;
    try std.testing.expectEqual(restored, restored_model.layout.focused().?);
    try std.testing.expectEqual(@as(u16, 1), restored_model.displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), restored_model.displayIndex(restored).?);
    try std.testing.expectEqual(@as(u16, 3), restored_model.displayIndex(@enumFromInt(77)).?);
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
    try saved.split(left, top_right, .horizontal);
    try saved.split(top_right, bottom_right, .vertical);
    try std.testing.expect(saved.focusPane(left));
    try std.testing.expect(saved.resizeFocused(.right, area));
    try std.testing.expect(saved.focusPane(top_right));
    try std.testing.expect(saved.resizeFocused(.down, area));
    var expected: layout_mod.Snapshot = .{};
    saved.snapshot(area, &expected);

    try model.bootstrap(top_right, location, .{ .cols = 30, .rows = 8 });
    try std.testing.expect(model.restoreLayoutOnNextSnapshot(location, saved));
    var buffer: [512]u8 = undefined;
    const snapshot = (try schema.decodeServer(try schema.encodeTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(3),
        .location = location,
        .panes = &.{
            .{ .pane_id = left, .lifecycle = .running },
            .{ .pane_id = top_right, .lifecycle = .running },
            .{ .pane_id = bottom_right, .lifecycle = .running },
        },
    }))).tab_snapshot;

    const restored = try model.reconcileTab(snapshot, area);
    var actual: layout_mod.Snapshot = .{};
    restored.model.layout.snapshot(area, &actual);
    for ([_]schema.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(expected.find(pane_id).?.outer, actual.find(pane_id).?.outer);
    try std.testing.expectEqual(top_right, restored.model.layout.focused().?);
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
    try saved.split(@enumFromInt(10), selected, .horizontal);
    try saved.split(selected, @enumFromInt(77), .vertical);

    try model.bootstrap(selected, location, .{ .cols = 30, .rows = 8 });
    try std.testing.expect(model.restoreLayoutOnNextSnapshot(location, saved));
    var buffer: [512]u8 = undefined;
    const snapshot = (try schema.decodeServer(try schema.encodeTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(3),
        .location = location,
        .panes = &.{
            .{ .pane_id = @enumFromInt(10), .lifecycle = .running },
            .{ .pane_id = selected, .lifecycle = .running },
            .{ .pane_id = @enumFromInt(88), .lifecycle = .running },
        },
    }))).tab_snapshot;

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
    try model.bootstrap(@enumFromInt(10), location, .{ .cols = 30, .rows = 8 });
    var buffer: [512]u8 = undefined;
    const initial = (try schema.decodeServer(try schema.encodeTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(3),
        .location = location,
        .panes = &.{
            .{ .pane_id = @enumFromInt(10), .lifecycle = .running },
            .{ .pane_id = @enumFromInt(42), .lifecycle = .running },
        },
    }))).tab_snapshot;
    const tab = try model.reconcileTab(initial, .{ .w = 60, .h = 12 });
    try tab.model.split(
        @enumFromInt(10),
        @enumFromInt(77),
        location,
        .vertical,
        .{ .w = 60, .h = 12 },
    );

    const refresh = (try schema.decodeServer(try schema.encodeTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(4),
        .location = location,
        .panes = &.{
            .{ .pane_id = @enumFromInt(10), .lifecycle = .running },
            .{ .pane_id = @enumFromInt(42), .lifecycle = .running },
            .{ .pane_id = @enumFromInt(77), .lifecycle = .running },
        },
    }))).tab_snapshot;
    _ = try model.reconcileTab(refresh, .{ .w = 60, .h = 12 });

    try std.testing.expectEqual(@as(u16, 1), tab.model.displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), tab.model.displayIndex(@enumFromInt(77)).?);
    try std.testing.expectEqual(@as(u16, 3), tab.model.displayIndex(@enumFromInt(42)).?);
}
