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

location: [capacity]core.TabLocation = undefined,
pane_id: [capacity]core.PaneId = undefined,
workspace_active: [capacity]bool = undefined,
presentation: [capacity]Presentation = undefined,
node_start: [capacity]u16 = undefined,
node_count: [capacity]u16 = undefined,
count: usize = 0,
nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined,
node_total: usize = 0,

/// Retains the latest split tree for one stable tab identity.
///
/// ```zig
/// try layouts.remember(saved);
/// ```
pub fn remember(self: *Layouts, saved: data.SavedLayout) !void {
    if (self.row(saved.location)) |existing| {
        self.remove(existing);
    }

    var storage: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    const tree = saved.layout.clientLayoutNodes(&storage);
    if (self.count == capacity or tree.len > self.nodes.len - self.node_total) {
        return error.TooManySavedLayouts;
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

test "saved trees keep their shape when an earlier tree leaves the pool" {
    var layouts: Layouts = .{};
    var trees: [3]data.WorkspaceLayout = @splat(.{});
    for (&trees, 0..) |*tree, index| {
        try tree.addRoot(@enumFromInt(10 * index + 1));
        for (0..index * 2) |split| {
            try tree.splitFocused(@enumFromInt(10 * index + split + 2), .vertical);
        }

        try layouts.remember(.{
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(1) },
                .tab_id = @enumFromInt(index + 1),
            },
            .pane_id = tree.focused().?,
            .workspace_active = index == 0,
            .layout = tree.*,
        });
    }

    const middle: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(2),
    };
    layouts.forget(middle);
    try std.testing.expect(layouts.find(middle) == null);
    for ([_]usize{ 0, 2 }) |index| {
        const restored = layouts.find(.{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(index + 1),
        }).?;
        var expected: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
        var actual: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
        try std.testing.expectEqualDeep(trees[index].clientLayoutNodes(&expected), restored.layout.clientLayoutNodes(&actual));
        try std.testing.expectEqual(trees[index].focused(), restored.layout.focused());
        try std.testing.expectEqual(trees[index].currentRevision(), restored.layout.currentRevision());
    }
}

test "a full node pool gives way to the oldest trees" {
    var layouts: Layouts = .{};
    var tree: data.WorkspaceLayout = .{};
    try tree.addRoot(@enumFromInt(1));
    for (1..core.max_panes_per_tab) |pane| {
        try tree.splitFocused(@enumFromInt(pane + 1), .vertical);
    }

    var saved: data.SavedLayout = .{
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_id = tree.focused().?,
        .workspace_active = true,
        .layout = tree,
    };
    const trees_that_fit = core.max_client_layout_nodes / core.max_client_layout_tab_nodes;
    for (0..trees_that_fit + 1) |index| {
        saved.location.tab_id = @enumFromInt(index + 1);
        layouts.retain(saved);
    }

    try std.testing.expectEqual(trees_that_fit, layouts.count);
    try std.testing.expect(layouts.find(.{ .workspace = saved.location.workspace, .tab_id = @enumFromInt(1) }) == null);
    try std.testing.expect(layouts.find(saved.location) != null);
}
