const Model = @This();
const std = @import("std");
const source_namespace = @import("tabs.zig");
const Tab = @import("Tab.zig");
const PendingLayoutRestore = @import("PendingLayoutRestore.zig");
const RootTab = @import("RootTab.zig");
const layout_mod = @import("layout_support.zig");
const multiplexer = @import("multiplexer.zig");
const PaneSnapshot = @import("PaneSnapshot.zig");
const WorkspaceSnapshotInput = @import("WorkspaceSnapshotInput.zig");
const WorkspaceTabInput = @import("WorkspaceTabInput.zig");
const CreatedTab = @import("CreatedTab.zig");
gpa: std.mem.Allocator,
workspace: ?source_namespace.schema.WorkspaceLocation = null,
workspace_name: [source_namespace.schema.max_workspace_name_bytes]u8 = undefined,
workspace_name_len: u16 = 0,
items: [source_namespace.max_tabs]?Tab = [_]?Tab{null} ** source_namespace.max_tabs,
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
        if (slot.*) |*tab| {
            tab.deinit();
        }
        slot.* = null;
    }
    model.count = 0;
    model.workspace = null;
    model.workspace_name_len = 0;
    model.pending_layout_restore = null;
}

pub fn setPaneGaps(model: *Model, enabled: bool) void {
    if (model.pane_gaps == enabled) {
        return;
    }
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

/// Creates the initial tab from its root pane description.
///
/// ```zig
/// try model.bootstrap(.{ .pane_id = pane_id, .location = location, .size = size });
/// ```
pub fn bootstrap(model: *Model, root: RootTab) !void {
    if (model.count != 0) {
        return error.ModelNotEmpty;
    }

    try model.replaceWithRoot(root);
}

/// Constructs a root tab before retiring the current workspace. Failure
/// preserves every existing tab and pane.
///
/// ```zig
/// try model.replaceWithRoot(root);
/// ```
pub fn replaceWithRoot(model: *Model, root: RootTab) !void {
    var tab = Tab.init(model.gpa, .{
        .location = root.location,
        .label = "main",
        .pane_gaps = model.pane_gaps,
    });
    errdefer tab.deinit();
    tab.model.setCellSize(model.cell_width_px, model.cell_height_px);
    try tab.model.addRoot(.{ .pane_id = root.pane_id, .location = root.location, .size = root.size });
    tab.restore_display_order = true;

    model.deinit();
    model.items[0] = tab;
    model.count = 1;
    model.active_index = 0;
    model.workspace = root.location.workspace;
}

pub fn restoreLayoutOnNextSnapshot(model: *Model, location: source_namespace.schema.TabLocation, saved: layout_mod.Layout) bool {
    if (model.find(location.tab_id) == null) {
        return false;
    }
    model.pending_layout_restore = .{ .location = location, .layout = saved };
    return true;
}

/// Stages a retained client tree including its saved pane focus. An
/// already staged arrival for this tab keeps its explicit navigation focus.
///
/// ```zig
/// _ = model.restoreClientLayoutOnNextSnapshot(location, saved);
/// ```
pub fn restoreClientLayoutOnNextSnapshot(model: *Model, location: source_namespace.schema.TabLocation, saved: layout_mod.Layout) bool {
    if (model.find(location.tab_id) == null) {
        return false;
    }

    if (model.pending_layout_restore) |pending| {
        if (std.meta.eql(pending.location, location)) {
            return true;
        }
    }

    model.pending_layout_restore = .{
        .location = location,
        .layout = saved,
        .restore_saved_focus = true,
    };
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
            if (slot.*) |*tab| {
                return tab;
            }
        }
        return null;
    }
};

pub fn tabIterator(model: *Model) TabIterator {
    return .{ .items = model.items[0..model.count] };
}

pub fn active(model: *Model) ?*Tab {
    if (model.count == 0) {
        return null;
    }
    return &model.items[model.active_index].?;
}

pub fn activeConst(model: *const Model) ?*const Tab {
    if (model.count == 0) {
        return null;
    }
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

pub fn find(model: *Model, tab_id: source_namespace.schema.TabId) ?*Tab {
    for (model.items[0..model.count]) |*slot| {
        const tab = if (slot.*) |*value| value else continue;
        if (tab.location.tab_id == tab_id) {
            return tab;
        }
    }
    return null;
}

pub fn indexOf(model: *const Model, tab_id: source_namespace.schema.TabId) ?usize {
    for (model.items[0..model.count], 0..) |slot, index|
        if (slot != null and slot.?.location.tab_id == tab_id) return index;
    return null;
}

pub fn findPane(model: *Model, pane_id: source_namespace.schema.PaneId) ?*multiplexer.Pane {
    for (model.items[0..model.count]) |*slot| {
        const tab = if (slot.*) |*value| value else continue;
        if (tab.model.find(pane_id)) |pane| {
            return pane;
        }
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
pub fn reconcileTab(model: *Model, snapshot: PaneSnapshot, area: source_namespace.ui.Rect) !*Tab {
    const tab = model.find(snapshot.location.tab_id) orelse return error.UnexpectedTab;
    if (!std.meta.eql(tab.location, snapshot.location)) {
        return error.UnexpectedTab;
    }
    if (snapshot.panes.len > multiplexer.max_panes) {
        return error.TooManyPanes;
    }
    for (snapshot.panes, 0..) |pane_id, index| {
        if (std.mem.findScalar(source_namespace.schema.PaneId, snapshot.panes[0..index], pane_id) != null) {
            return error.DuplicatePane;
        }
    }

    const focused_before = tab.model.layout.focused();
    var removed: [multiplexer.max_panes]source_namespace.schema.PaneId = undefined;
    var removed_count: usize = 0;
    for (&tab.model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        if (std.mem.findScalar(source_namespace.schema.PaneId, snapshot.panes, pane.id) == null) {
            removed[removed_count] = pane.id;
            removed_count += 1;
        }
    }

    for (removed[0..removed_count]) |pane_id| {
        _ = tab.model.removePane(pane_id);
    }

    for (snapshot.panes) |pane_id| {
        if (tab.model.find(pane_id) == null) {
            try tab.model.addDiscovered(.{ .pane_id = pane_id, .location = snapshot.location, .area = area });
        }
    }

    var focus_after = tab.model.layout.focused();
    if (focused_before) |pane_id| {
        if (std.mem.findScalar(source_namespace.schema.PaneId, snapshot.panes, pane_id) != null) {
            focus_after = pane_id;
        }
    }

    if (focus_after) |pane_id| {
        const restored_layout = if (model.pending_layout_restore) |pending|
            std.meta.eql(pending.location, snapshot.location) and
                tab.model.restoreSavedLayout(
                    pending.layout,
                    .{
                        .ids = snapshot.panes,
                        .focused = if (pending.restore_saved_focus) pending.layout.focused() orelse pane_id else pane_id,
                    },
                )
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

pub fn tabForPane(model: *Model, pane_id: source_namespace.schema.PaneId) ?*Tab {
    for (model.items[0..model.count]) |*slot| {
        const tab = if (slot.*) |*value| value else continue;
        if (tab.model.find(pane_id) != null) {
            return tab;
        }
    }
    return null;
}

/// Finds the tab containing one pane without exposing mutable storage.
///
/// ```zig
/// const tab = model.tabForPaneConst(pane_id) orelse return;
/// ```
pub fn tabForPaneConst(model: *const Model, pane_id: source_namespace.schema.PaneId) ?*const Tab {
    for (model.items[0..model.count]) |*slot| {
        const tab = if (slot.*) |*value| value else continue;
        if (tab.model.findConst(pane_id) != null) {
            return tab;
        }
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

    if (snapshot.tabs.len > source_namespace.max_tabs) {
        return error.TabLimitReached;
    }

    if (snapshot.name.len == 0 or snapshot.name.len > source_namespace.schema.max_workspace_name_bytes or
        std.mem.findScalar(u8, snapshot.name, 0) != null)
    {
        return error.InvalidWorkspaceName;
    }

    for (snapshot.tabs, 0..) |descriptor, index| {
        if (descriptor.tab_id == .invalid) {
            return error.InvalidTabId;
        }

        if (descriptor.pane_count > source_namespace.schema.max_panes_per_tab) {
            return error.TooManyPanes;
        }

        try source_namespace.validateLabel(descriptor.label);
        for (snapshot.tabs[0..index]) |previous| {
            if (previous.tab_id == descriptor.tab_id) {
                return error.DuplicateTab;
            }
        }
    }

    const active_id = (model.activeConst() orelse return error.WorkspaceHasNoTabs).location.tab_id;
    var canonical_ids: [source_namespace.max_tabs]source_namespace.schema.TabId = undefined;
    for (snapshot.tabs, 0..) |descriptor, index| {
        canonical_ids[index] = descriptor.tab_id;
    }

    var current = model.count;
    while (current > 0) {
        current -= 1;
        const tab_id = model.items[current].?.location.tab_id;
        if (std.mem.findScalar(source_namespace.schema.TabId, canonical_ids[0..snapshot.tabs.len], tab_id) == null) {
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
        if (std.mem.findScalar(source_namespace.schema.TabId, canonical_ids[0..snapshot.tabs.len], pending.location.tab_id) == null) {
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
    std.debug.assert(model.count < source_namespace.max_tabs);
    std.debug.assert(index <= model.count);

    var cursor = model.count;
    while (cursor > index) : (cursor -= 1) {
        model.items[cursor] = model.items[cursor - 1];
    }

    model.items[index] = Tab.init(model.gpa, .{
        .location = .{
            .workspace = model.workspace.?,
            .tab_id = descriptor.tab_id,
        },
        .label = descriptor.label,
        .pane_gaps = model.pane_gaps,
    });
    model.items[index].?.model.setCellSize(model.cell_width_px, model.cell_height_px);
    model.count += 1;
}

/// Adds a runtime-confirmed tab and makes it active.
///
/// ```zig
/// const tab = try model.addCreated(created, size);
/// ```
pub fn addCreated(model: *Model, created: CreatedTab, size: source_namespace.schema.TerminalSize) !*Tab {
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
    if (model.count == source_namespace.max_tabs) {
        return error.TabLimitReached;
    }
    if (created.position > model.count) {
        return error.InvalidTabPosition;
    }

    var tab = Tab.init(model.gpa, .{
        .location = created.location,
        .label = created.label,
        .pane_gaps = model.pane_gaps,
    });
    errdefer tab.deinit();
    tab.model.setCellSize(model.cell_width_px, model.cell_height_px);
    try tab.model.addRoot(.{ .pane_id = created.root_pane_id, .location = created.location, .size = size });
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
pub fn applyLabel(model: *Model, tab_id: source_namespace.schema.TabId, label: []const u8) !source_namespace.LabelChange {
    const tab = model.find(tab_id) orelse return error.TabNotFound;
    try source_namespace.validateLabel(label);

    if (std.mem.eql(u8, tab.labelSlice(), label)) {
        return .unchanged;
    }

    tab.setLabel(label);
    return .changed;
}

pub fn select(model: *Model, tab_id: source_namespace.schema.TabId) bool {
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
pub fn applyPosition(model: *Model, tab_id: source_namespace.schema.TabId, position: u16) !source_namespace.PositionChange {
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

pub fn remove(model: *Model, tab_id: source_namespace.schema.TabId) bool {
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
