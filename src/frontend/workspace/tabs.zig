//! Disposable client state for the ordered tabs of one workspace.

const std = @import("std");
const core = @import("telar-core");
const layout_mod = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");
const ui = core.ui;

const schema = core.schema;

pub const max_tabs = schema.max_tabs_per_workspace;

pub const PositionChange = enum {
    unchanged,
    changed,
};

pub const LabelChange = enum {
    unchanged,
    changed,
};

fn validateLabel(label: []const u8) !void {
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

pub const CreatedTab = struct {
    location: schema.TabLocation,
    position: u16,
    label: []const u8,
    root_pane_id: schema.PaneId,
};

pub const WorkspaceTabInput = struct {
    tab_id: schema.TabId,
    pane_count: u16,
    label: []const u8,
};

pub const WorkspaceSnapshotInput = struct {
    workspace: schema.WorkspaceLocation,
    name: []const u8,
    /// Borrowed only for synchronous reconciliation. Slice order is the
    /// canonical runtime tab order.
    tabs: []const WorkspaceTabInput,
};

pub const PaneSnapshot = struct {
    location: schema.TabLocation,
    /// Borrowed only for synchronous reconciliation. Order is the canonical
    /// display order used when a tab has no retained client layout.
    panes: []const schema.PaneId,
};

pub const RootTab = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    size: schema.TerminalSize,
};

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
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,
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

    /// Sets the host cell geometry for current and future tabs.
    ///
    /// ```zig
    /// model.setCellSize(8, 16);
    /// ```
    pub fn setCellSize(model: *Model, width: u16, height: u16) void {
        if (model.cell_width_px == width and model.cell_height_px == height) {
            return;
        }

        model.cell_width_px = width;
        model.cell_height_px = height;
        for (model.items[0..model.count]) |*slot| {
            if (slot.*) |*tab| {
                tab.model.setCellSize(width, height);
            }
        }
    }

    pub fn bootstrap(
        model: *Model,
        pane_id: schema.PaneId,
        location: schema.TabLocation,
        size: schema.TerminalSize,
    ) !void {
        if (model.count != 0) return error.ModelNotEmpty;

        try model.replaceWithRoot(.{
            .pane_id = pane_id,
            .location = location,
            .size = size,
        });
    }

    /// Constructs a root tab before retiring the current workspace. Failure
    /// preserves every existing tab and pane.
    ///
    /// ```zig
    /// try model.replaceWithRoot(root);
    /// ```
    pub fn replaceWithRoot(model: *Model, root: RootTab) !void {
        var tab = Tab.init(model.gpa, root.location, "main", model.pane_gaps);
        errdefer tab.deinit();
        tab.model.setCellSize(model.cell_width_px, model.cell_height_px);
        try tab.model.addRoot(root.pane_id, root.location, root.size);
        tab.restore_display_order = true;

        model.deinit();
        model.items[0] = tab;
        model.count = 1;
        model.active_index = 0;
        model.workspace = root.location.workspace;
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

    /// Reconciles canonical pane membership while retaining matching pane
    /// buffers and client layout state.
    ///
    /// ```zig
    /// const tab = try model.reconcileTab(snapshot, workbench);
    /// ```
    pub fn reconcileTab(model: *Model, snapshot: PaneSnapshot, area: ui.Rect) !*Tab {
        const tab = model.find(snapshot.location.tab_id) orelse return error.UnexpectedTab;
        if (!std.meta.eql(tab.location, snapshot.location)) {
            return error.UnexpectedTab;
        }
        if (snapshot.panes.len > multiplexer.max_panes) {
            return error.TooManyPanes;
        }
        for (snapshot.panes, 0..) |pane_id, index| {
            if (std.mem.findScalar(schema.PaneId, snapshot.panes[0..index], pane_id) != null) {
                return error.DuplicatePane;
            }
        }

        const focused_before = tab.model.layout.focused();
        var removed: [multiplexer.max_panes]schema.PaneId = undefined;
        var removed_count: usize = 0;
        for (&tab.model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            if (std.mem.findScalar(schema.PaneId, snapshot.panes, pane.id) == null) {
                removed[removed_count] = pane.id;
                removed_count += 1;
            }
        }

        for (removed[0..removed_count]) |pane_id| {
            _ = tab.model.removePane(pane_id);
        }

        for (snapshot.panes) |pane_id| {
            if (tab.model.find(pane_id) == null) {
                try tab.model.addDiscovered(pane_id, snapshot.location, area);
            }
        }

        var focus_after = tab.model.layout.focused();
        if (focused_before) |pane_id| {
            if (std.mem.findScalar(schema.PaneId, snapshot.panes, pane_id) != null) {
                focus_after = pane_id;
            }
        }

        if (focus_after) |pane_id| {
            const restored_layout = if (model.pending_layout_restore) |pending|
                std.meta.eql(pending.location, snapshot.location) and
                    tab.model.restoreSavedLayout(pending.layout, snapshot.panes, pane_id)
            else
                false;
            if (model.pending_layout_restore) |pending| {
                if (std.meta.eql(pending.location, snapshot.location)) {
                    model.pending_layout_restore = null;
                }
            }

            if (!restored_layout) {
                if (tab.restore_display_order) {
                    try tab.model.restoreDisplayOrder(snapshot.panes, pane_id);
                } else {
                    _ = tab.model.focusPane(pane_id);
                }
            }
        }

        tab.restore_display_order = false;
        tab.snapshot_loaded = true;
        return tab;
    }

    pub fn tabForPane(model: *Model, pane_id: schema.PaneId) ?*Tab {
        for (model.items[0..model.count]) |*slot| {
            const tab = if (slot.*) |*value| value else continue;
            if (tab.model.find(pane_id) != null) return tab;
        }
        return null;
    }

    /// Reconciles one canonical snapshot without replacing retained tab
    /// layouts. Validation completes before the first mutation.
    ///
    /// ```zig
    /// try model.reconcileWorkspace(snapshot);
    /// ```
    pub fn reconcileWorkspace(model: *Model, snapshot: WorkspaceSnapshotInput) !void {
        if (model.workspace == null or !std.meta.eql(model.workspace.?, snapshot.workspace)) {
            return error.UnexpectedWorkspace;
        }

        if (snapshot.tabs.len == 0) {
            return error.WorkspaceHasNoTabs;
        }

        if (snapshot.tabs.len > max_tabs) {
            return error.TabLimitReached;
        }

        if (snapshot.name.len == 0 or snapshot.name.len > schema.max_workspace_name_bytes or
            std.mem.findScalar(u8, snapshot.name, 0) != null)
        {
            return error.InvalidWorkspaceName;
        }

        for (snapshot.tabs, 0..) |descriptor, index| {
            if (descriptor.tab_id == .invalid) {
                return error.InvalidTabId;
            }

            if (descriptor.pane_count > schema.max_panes_per_tab) {
                return error.TooManyPanes;
            }

            try validateLabel(descriptor.label);
            for (snapshot.tabs[0..index]) |previous| {
                if (previous.tab_id == descriptor.tab_id) {
                    return error.DuplicateTab;
                }
            }
        }

        const active_id = (model.activeConst() orelse return error.WorkspaceHasNoTabs).location.tab_id;
        var canonical_ids: [max_tabs]schema.TabId = undefined;
        for (snapshot.tabs, 0..) |descriptor, index| {
            canonical_ids[index] = descriptor.tab_id;
        }

        var current = model.count;
        while (current > 0) {
            current -= 1;
            const tab_id = model.items[current].?.location.tab_id;
            if (std.mem.findScalar(schema.TabId, canonical_ids[0..snapshot.tabs.len], tab_id) == null) {
                model.removeForReconciliation(current);
            }
        }

        for (snapshot.tabs, 0..) |descriptor, index| {
            if (model.indexOf(descriptor.tab_id)) |existing_index| {
                if (existing_index != index) {
                    std.mem.swap(?Tab, &model.items[existing_index], &model.items[index]);
                }
            } else {
                model.insertDiscovered(descriptor, index);
            }

            const tab = &model.items[index].?;
            tab.setLabel(descriptor.label);
            if (tab.model.pane_count != descriptor.pane_count) {
                tab.snapshot_loaded = false;
            }
        }

        std.debug.assert(model.count == snapshot.tabs.len);
        if (model.pending_layout_restore) |pending| {
            if (std.mem.findScalar(schema.TabId, canonical_ids[0..snapshot.tabs.len], pending.location.tab_id) == null) {
                model.pending_layout_restore = null;
            }
        }

        @memcpy(model.workspace_name[0..snapshot.name.len], snapshot.name);
        model.workspace_name_len = @intCast(snapshot.name.len);
        model.active_index = model.indexOf(active_id) orelse 0;
    }

    fn removeForReconciliation(model: *Model, index: usize) void {
        model.items[index].?.deinit();

        var cursor = index;
        while (cursor + 1 < model.count) : (cursor += 1) {
            model.items[cursor] = model.items[cursor + 1];
        }

        model.count -= 1;
        model.items[model.count] = null;
    }

    fn insertDiscovered(model: *Model, descriptor: WorkspaceTabInput, index: usize) void {
        std.debug.assert(model.count < max_tabs);
        std.debug.assert(index <= model.count);

        var cursor = model.count;
        while (cursor > index) : (cursor -= 1) {
            model.items[cursor] = model.items[cursor - 1];
        }

        model.items[index] = Tab.init(model.gpa, .{
            .workspace = model.workspace.?,
            .tab_id = descriptor.tab_id,
        }, descriptor.label, model.pane_gaps);
        model.items[index].?.model.setCellSize(model.cell_width_px, model.cell_height_px);
        model.count += 1;
    }

    /// Adds a runtime-confirmed tab and makes it active.
    ///
    /// ```zig
    /// const tab = try model.addCreated(created, size);
    /// ```
    pub fn addCreated(model: *Model, created: CreatedTab, size: schema.TerminalSize) !*Tab {
        const workspace = model.workspace orelse return error.UnexpectedWorkspace;
        if (!std.meta.eql(workspace, created.location.workspace)) {
            return error.UnexpectedWorkspace;
        }
        if (model.indexOf(created.location.tab_id) != null) {
            return error.TabAlreadyExists;
        }
        if (model.findPane(created.root_pane_id) != null) {
            return error.PaneAlreadyExists;
        }
        if (model.count == max_tabs) {
            return error.TabLimitReached;
        }
        if (created.position > model.count) {
            return error.InvalidTabPosition;
        }

        var tab = Tab.init(model.gpa, created.location, created.label, model.pane_gaps);
        errdefer tab.deinit();
        tab.model.setCellSize(model.cell_width_px, model.cell_height_px);
        try tab.model.addRoot(created.root_pane_id, created.location, size);
        tab.snapshot_loaded = true;

        var cursor = model.count;
        while (cursor > created.position) : (cursor -= 1) {
            model.items[cursor] = model.items[cursor - 1];
        }

        model.items[created.position] = tab;
        model.count += 1;
        model.active_index = created.position;

        return &model.items[created.position].?;
    }

    /// Applies one canonical label and reports whether visible state changed.
    ///
    /// ```zig
    /// const change = try model.applyLabel(tab_id, "server");
    /// ```
    pub fn applyLabel(model: *Model, tab_id: schema.TabId, label: []const u8) !LabelChange {
        const tab = model.find(tab_id) orelse return error.TabNotFound;
        try validateLabel(label);

        if (std.mem.eql(u8, tab.labelSlice(), label)) {
            return .unchanged;
        }

        tab.setLabel(label);
        return .changed;
    }

    pub fn select(model: *Model, tab_id: schema.TabId) bool {
        const index = model.indexOf(tab_id) orelse return false;
        if (index == model.active_index) {
            return false;
        }

        model.active_index = index;
        return true;
    }

    pub fn selectOffset(model: *Model, offset: isize) bool {
        if (model.count < 2) {
            return false;
        }

        const count: isize = @intCast(model.count);
        const wrapped_offset: usize = @intCast(@mod(offset, count));
        const position = (model.active_index + wrapped_offset) % model.count;

        return model.selectPosition(position);
    }

    pub fn selectPosition(model: *Model, position: usize) bool {
        if (position >= model.count or position == model.active_index) {
            return false;
        }

        model.active_index = position;
        return true;
    }

    /// Applies a canonical runtime position while preserving the active tab.
    ///
    /// ```zig
    /// const change = try model.applyPosition(tab_id, 1);
    /// ```
    pub fn applyPosition(model: *Model, tab_id: schema.TabId, position: u16) !PositionChange {
        const from = model.indexOf(tab_id) orelse return error.TabNotFound;
        const target: usize = position;
        if (target >= model.count) {
            return error.InvalidTabPosition;
        }

        if (from == target) {
            return .unchanged;
        }

        const active_id = model.activeConst().?.location.tab_id;
        if (from < target) {
            var index = from;
            while (index < target) : (index += 1) {
                std.mem.swap(?Tab, &model.items[index], &model.items[index + 1]);
            }
        } else {
            var index = from;
            while (index > target) : (index -= 1) {
                std.mem.swap(?Tab, &model.items[index], &model.items[index - 1]);
            }
        }

        model.active_index = model.indexOf(active_id).?;
        return .changed;
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
    try model.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });

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
    try model.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
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
    try model.bootstrap(previous_pane, previous, .{ .cols = 20, .rows = 5 });
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
    try model.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
    @memcpy(model.workspace_name[0..5], "telar");
    model.workspace_name_len = 5;

    const tab = model.active().?;
    try std.testing.expectEqual(
        multiplexer.MetadataChange.display_changed,
        try tab.model.setPaneCwd(@enumFromInt(1), "/work/telar"),
    );
    try std.testing.expectEqualStrings("telar", model.displayedWorkspaceName());
    try tab.model.split(
        @enumFromInt(1),
        @enumFromInt(2),
        tab.location,
        .horizontal,
        .{ .x = 0, .y = 0, .w = 20, .h = 5 },
    );
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
    try model.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
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
    try model.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
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
    try model.bootstrap(@enumFromInt(7), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
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
    try model.bootstrap(root_pane, .{
        .workspace = workspace,
        .tab_id = root_tab,
    }, .{ .cols = 20, .rows = 5 });

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
    try model.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 2, .rows = 1 });
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
    try model.bootstrap(restored, location, .{ .cols = 30, .rows = 8 });
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
    try model.bootstrap(vanished, location, .{ .cols = 30, .rows = 8 });
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
    try model.bootstrap(root_pane, location, .{ .cols = 30, .rows = 8 });
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
    try model.bootstrap(@enumFromInt(10), location, .{ .cols = 30, .rows = 8 });
    const initial: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), @enumFromInt(42) },
    };
    const tab = try model.reconcileTab(initial, .{ .w = 60, .h = 12 });
    try tab.model.split(
        @enumFromInt(10),
        @enumFromInt(77),
        location,
        .vertical,
        .{ .w = 60, .h = 12 },
    );

    const refresh: PaneSnapshot = .{
        .location = location,
        .panes = &.{ @enumFromInt(10), @enumFromInt(42), @enumFromInt(77) },
    };
    _ = try model.reconcileTab(refresh, .{ .w = 60, .h = 12 });

    try std.testing.expectEqual(@as(u16, 1), tab.model.displayIndex(@enumFromInt(10)).?);
    try std.testing.expectEqual(@as(u16, 2), tab.model.displayIndex(@enumFromInt(77)).?);
    try std.testing.expectEqual(@as(u16, 3), tab.model.displayIndex(@enumFromInt(42)).?);
}
