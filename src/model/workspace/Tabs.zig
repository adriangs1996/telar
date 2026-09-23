//! The ordered tabs of the client's workspace. A tab's slot is its position,
//! so slots change when tabs move; relations use `core.TabId`.
const core = @import("telar-core");
const std = @import("std");
const WorkspaceLayout = @import("WorkspaceLayout.zig");
const Tabs = @This();

pub const capacity = core.max_tabs_per_workspace;
const Label = [core.max_tab_label_bytes]u8;
const ForegroundName = [core.max_foreground_name_bytes]u8;

location: [capacity]core.TabLocation = undefined,
/// An empty canonical label follows the focused foreground application.
label: [capacity]Label = undefined,
label_len: [capacity]u8 = @splat(0),
layout: [capacity]WorkspaceLayout = undefined,
/// Whether the runtime's pane snapshot for this tab has been reconciled.
snapshot_loaded: [capacity]bool = @splat(false),
/// Whether the next snapshot restores the runtime's display order.
restore_display_order: [capacity]bool = @splat(false),
/// The pane whose foreground names the tab before its panes attach.
foreground_pane: [capacity]core.PaneId = @splat(.invalid),
foreground_name: [capacity]ForegroundName = undefined,
foreground_name_len: [capacity]u8 = @splat(0),
count: usize = 0,
active: usize = 0,

/// Inserts an empty tab at `position` and returns its slot.
/// Example: `const slot = model.tabs.insert(position, location, "", pane_gaps);`
pub fn insert(self: *Tabs, position: usize, location: core.TabLocation, pane_gaps: bool) usize {
    std.debug.assert(self.count < capacity);
    std.debug.assert(position <= self.count);

    var cursor = self.count;
    while (cursor > position) : (cursor -= 1) {
        self.copy(cursor - 1, cursor);
    }

    self.location[position] = location;
    self.label_len[position] = 0;
    self.layout[position] = .{};
    _ = self.layout[position].setPaneGaps(pane_gaps);
    self.snapshot_loaded[position] = false;
    self.restore_display_order[position] = false;
    self.foreground_pane[position] = .invalid;
    self.foreground_name_len[position] = 0;
    self.count += 1;
    return position;
}

/// Removes the tab at `slot`, keeping the remaining order.
/// Example: `model.tabs.remove(slot);`
pub fn remove(self: *Tabs, slot: usize) void {
    std.debug.assert(slot < self.count);

    var cursor = slot;
    while (cursor + 1 < self.count) : (cursor += 1) {
        self.copy(cursor + 1, cursor);
    }

    self.count -= 1;
}

/// Moves one tab to `target`, shifting the tabs between them.
/// Example: `model.tabs.move(from, to);`
pub fn move(self: *Tabs, from: usize, target: usize) void {
    std.debug.assert(from < self.count and target < self.count);
    if (from == target) {
        return;
    }

    const moved = self.row(from);
    if (from < target) {
        for (from..target) |cursor| {
            self.copy(cursor + 1, cursor);
        }
    } else {
        var cursor = from;
        while (cursor > target) : (cursor -= 1) {
            self.copy(cursor - 1, cursor);
        }
    }

    self.store(target, moved);
}

/// Example: `const slot = model.tabs.find(tab_id) orelse return;`
pub fn find(self: *const Tabs, tab_id: core.TabId) ?usize {
    for (self.location[0..self.count], 0..) |location, slot| {
        if (location.tab_id == tab_id) {
            return slot;
        }
    }

    return null;
}

/// Example: `const slot = model.tabs.activeSlot() orelse return;`
pub fn activeSlot(self: *const Tabs) ?usize {
    return if (self.count == 0) null else self.active;
}

/// The label the runtime stores, empty when the tab follows its foreground.
/// Example: `const label = model.tabs.canonicalLabel(slot);`
pub fn canonicalLabel(self: *const Tabs, slot: usize) []const u8 {
    return self.label[slot][0..self.label_len[slot]];
}

/// Example: `model.tabs.setLabel(slot, "server");`
pub fn setLabel(self: *Tabs, slot: usize, label: []const u8) void {
    std.debug.assert(label.len <= core.max_tab_label_bytes);
    @memcpy(self.label[slot][0..label.len], label);
    self.label_len[slot] = @intCast(label.len);
}

/// Example: `const name = model.tabs.foregroundName(slot);`
pub fn foregroundName(self: *const Tabs, slot: usize) []const u8 {
    return self.foreground_name[slot][0..self.foreground_name_len[slot]];
}

/// Example: `model.tabs.setForegroundName(slot, "vim");`
pub fn setForegroundName(self: *Tabs, slot: usize, name: []const u8) void {
    std.debug.assert(name.len <= core.max_foreground_name_bytes);
    @memcpy(self.foreground_name[slot][0..name.len], name);
    self.foreground_name_len[slot] = @intCast(name.len);
}

const Row = struct {
    location: core.TabLocation,
    label: Label,
    label_len: u8,
    layout: WorkspaceLayout,
    snapshot_loaded: bool,
    restore_display_order: bool,
    foreground_pane: core.PaneId,
    foreground_name: ForegroundName,
    foreground_name_len: u8,
};

fn row(self: *const Tabs, slot: usize) Row {
    return .{
        .location = self.location[slot],
        .label = self.label[slot],
        .label_len = self.label_len[slot],
        .layout = self.layout[slot],
        .snapshot_loaded = self.snapshot_loaded[slot],
        .restore_display_order = self.restore_display_order[slot],
        .foreground_pane = self.foreground_pane[slot],
        .foreground_name = self.foreground_name[slot],
        .foreground_name_len = self.foreground_name_len[slot],
    };
}

fn store(self: *Tabs, slot: usize, value: Row) void {
    self.location[slot] = value.location;
    self.label[slot] = value.label;
    self.label_len[slot] = value.label_len;
    self.layout[slot] = value.layout;
    self.snapshot_loaded[slot] = value.snapshot_loaded;
    self.restore_display_order[slot] = value.restore_display_order;
    self.foreground_pane[slot] = value.foreground_pane;
    self.foreground_name[slot] = value.foreground_name;
    self.foreground_name_len[slot] = value.foreground_name_len;
}

fn copy(self: *Tabs, from: usize, to: usize) void {
    self.store(to, self.row(from));
}
