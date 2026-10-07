//! Split trees the client keeps for the tabs of every workspace it visited,
//! so returning to a workspace restores each tab's arrangement. Rows keep
//! the order they were saved in and their trees share one node pool, so the
//! oldest row is the one that makes room.
const core = @import("telar-core");
const data = @import("../model.zig");
const Metrics = @import("Metrics.zig");
const std = @import("std");
const Layouts = @This();

/// Every tab the runtime holds has a pane, so its tabs all fit.
pub const capacity = core.max_client_layout_tabs;

// SAFETY: remember writes the location before increasing count; row lookup and compaction use only occupied rows.
location: [capacity]core.TabLocation = undefined,
// SAFETY: remember writes the focused pane before increasing count; find reads it only after locating an occupied row.
pane_id: [capacity]core.PaneId = undefined,
// SAFETY: remember writes the active flag before increasing count; find and compaction use only occupied rows.
workspace_active: [capacity]bool = undefined,
// SAFETY: remember fills the presentation before increasing count; find reads it only after locating an occupied row.
presentation: [capacity]Presentation = undefined,
// SAFETY: remember writes each tree offset before increasing count; lookup and compaction use offsets of occupied rows.
node_start: [capacity]u16 = undefined,
// SAFETY: remember writes each tree length before increasing count; lookup and compaction use lengths of occupied rows.
node_count: [capacity]u16 = undefined,
count: usize = 0,
// SAFETY: remember copies tree nodes before increasing node_total and count; lookup and compaction use only retained tree ranges.
nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined,
node_total: usize = 0,

/// Retains the latest split tree for one stable tab identity. A tree that
/// does not fit leaves every saved one, the tab's own included, in place.
///
/// ```zig
/// try layouts.remember(saved);
/// ```
pub fn remember(self: *Layouts, saved: data.SavedLayout) !void {
    var storage: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    const tree = saved.layout.clientLayoutNodes(&storage);
    const existing = self.row(saved.location);
    const freed_rows: usize = if (existing != null) 1 else 0;
    const freed_nodes: usize = if (existing) |slot| self.node_count[slot] else 0;
    if (self.count - freed_rows == capacity or tree.len > self.nodes.len - self.node_total + freed_nodes) {
        return error.TooManySavedLayouts;
    }

    if (existing) |slot| {
        self.remove(slot);
    }

    const slot = self.count;
    self.location[slot] = saved.location;
    self.pane_id[slot] = saved.pane_id;
    self.workspace_active[slot] = saved.workspace_active;
    self.presentation[slot] = .{
        .focused_pane = saved.layout.focused_pane,
        .fullscreen = saved.layout.fullscreen,
        .pane_gaps = saved.layout.pane_gaps,
        .metrics = saved.layout.metrics,
        .revision = saved.layout.revision,
    };
    self.node_start[slot] = @intCast(self.node_total);
    self.node_count[slot] = @intCast(tree.len);
    @memcpy(self.nodes[self.node_total..][0..tree.len], tree);
    self.node_total += tree.len;
    self.count += 1;
}

/// Retains a live layout without blocking navigation when the table fills:
/// the oldest rows make room. An evicted tab falls back to canonical pane
/// order on its next visit.
///
/// ```zig
/// layouts.retain(saved);
/// ```
pub fn retain(self: *Layouts, saved: data.SavedLayout) void {
    while (true) {
        self.remember(saved) catch {
            if (self.count == 0) {
                return;
            }

            self.remove(0);
            continue;
        };

        return;
    }
}

/// Finds a retained tab layout without changing its lifetime.
///
/// ```zig
/// const saved = layouts.find(location) orelse return;
/// ```
pub fn find(self: *const Layouts, location: core.TabLocation) ?data.SavedLayout {
    const slot = self.row(location) orelse return null;
    const presentation = self.presentation[slot];
    var layout = data.WorkspaceLayout.fromClientLayoutNodes(.{
        .location = location,
        .focused_pane = presentation.focused_pane,
        .fullscreen = presentation.fullscreen,
        .nodes = self.nodes[self.node_start[slot]..][0..self.node_count[slot]],
    }) catch return null;
    layout.pane_gaps = presentation.pane_gaps;
    layout.metrics = presentation.metrics;
    layout.revision = presentation.revision;
    return .{
        .location = location,
        .pane_id = self.pane_id[slot],
        .workspace_active = self.workspace_active[slot],
        .layout = layout,
    };
}

/// Removes one layout after canonical pane reconciliation consumes it.
///
/// ```zig
/// layouts.forget(location);
/// ```
pub fn forget(self: *Layouts, location: core.TabLocation) void {
    const slot = self.row(location) orelse return;
    self.remove(slot);
}

fn row(self: *const Layouts, location: core.TabLocation) ?usize {
    for (self.location[0..self.count], 0..) |candidate, slot| {
        if (std.meta.eql(candidate, location)) {
            return slot;
        }
    }

    return null;
}

/// Removes one row and closes the gap its tree left in the pool.
fn remove(self: *Layouts, slot: usize) void {
    const start = self.node_start[slot];
    const len = self.node_count[slot];
    std.mem.copyForwards(core.ClientLayoutNode, self.nodes[start..], self.nodes[start + len .. self.node_total]);
    self.node_total -= len;
    const last = self.count - 1;
    std.mem.copyForwards(core.TabLocation, self.location[slot..], self.location[slot + 1 .. self.count]);
    std.mem.copyForwards(core.PaneId, self.pane_id[slot..], self.pane_id[slot + 1 .. self.count]);
    std.mem.copyForwards(bool, self.workspace_active[slot..], self.workspace_active[slot + 1 .. self.count]);
    std.mem.copyForwards(Presentation, self.presentation[slot..], self.presentation[slot + 1 .. self.count]);
    std.mem.copyForwards(u16, self.node_start[slot..], self.node_start[slot + 1 .. self.count]);
    std.mem.copyForwards(u16, self.node_count[slot..], self.node_count[slot + 1 .. self.count]);
    self.count = last;
    for (self.node_start[slot..self.count]) |*moved| {
        moved.* -= len;
    }
}

/// What a saved tab keeps of its layout besides the tree.
const Presentation = struct {
    focused_pane: core.PaneId,
    fullscreen: bool,
    pane_gaps: bool,
    metrics: Metrics,
    revision: u64,
};
