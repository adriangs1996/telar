const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const layout_support = @import("layout_support.zig");
const Slot = @import("Slot.zig");
const Metrics = @import("Metrics.zig");
const std = @import("std");
const ClientLayoutBuilder = @import("ClientLayoutBuilder.zig");
const PaneSet = @import("PaneSet.zig");
const SplitRequest = @import("SplitRequest.zig");
const LayoutSnapshot = @import("LayoutSnapshot.zig");
const SplitTarget = @import("SplitTarget.zig");
const ProspectiveSplit = @import("ProspectiveSplit.zig");
const View = @import("LayoutView.zig");
const Split = @import("Split.zig");
const RatioCandidate = @import("RatioCandidate.zig");
const Layout = @This();

nodes: [layout_support.max_nodes]Slot = [_]Slot{
    .{},
} ** layout_support.max_nodes,
root: ?layout_support.NodeIndex = null,
focused_pane: core.PaneId = .invalid,
pane_count: u8 = 0,
fullscreen: bool = false,
pane_gaps: bool = true,
metrics: Metrics = .{},
revision: u64 = 1,

/// Installs presentation measurements without changing topology or ratios.
/// Example: `_ = layout.setMetrics(.{ .border = 0, .gap = 0 });`.
pub fn setMetrics(self: *Layout, metrics: Metrics) bool {
    if (std.meta.eql(self.metrics, metrics)) {
        return false;
    }

    self.metrics = metrics;
    self.changed();
    return true;
}

pub fn count(self: *const Layout) usize {
    return self.pane_count;
}

pub fn focused(self: *const Layout) ?core.PaneId {
    return if (self.focused_pane == .invalid) null else self.focused_pane;
}

pub fn currentRevision(self: *const Layout) u64 {
    return self.revision;
}

pub fn isFullscreen(self: *const Layout) bool {
    return self.fullscreen;
}

/// Fullscreen keeps its label border even when the tab has only one pane.
/// Example: `if (layout.hasBorders()) drawPaneBorder();`.
pub fn hasBorders(self: *const Layout) bool {
    return self.metrics.border != 0 and (self.fullscreen or self.pane_count > 1);
}

/// Writes this split tree in the protocol's pre-order representation.
///
/// ```zig
/// var nodes: [schema.max_client_layout_tab_nodes]schema.ClientLayoutNode = undefined;
/// const encoded = layout.clientLayoutNodes(&nodes);
/// ```
pub fn clientLayoutNodes(self: *const Layout, output: *[core.max_client_layout_tab_nodes]core.ClientLayoutNode) []const core.ClientLayoutNode {
    const root = self.root orelse return output[0..0];
    var stack: [layout_support.max_nodes]layout_support.NodeIndex = undefined;
    var stack_len: usize = 1;
    var output_len: usize = 0;
    stack[0] = root;
    while (stack_len != 0) {
        stack_len -= 1;
        const slot = self.nodes[stack[stack_len]];
        output[output_len] = switch (slot.node) {
            .empty => unreachable,
            .leaf => |pane_id| .{
                .pane = .{
                    .id = pane_id,
                },
            },
            .split => |branch| encoded: {
                stack[stack_len] = branch.second;
                stack_len += 1;
                stack[stack_len] = branch.first;
                stack_len += 1;
                break :encoded .{
                    .split = .{
                        .axis = switch (branch.axis) {
                            .horizontal => .horizontal,
                            .vertical => .vertical,
                        },
                        .ratio = branch.ratio,
                    },
                };
            },
        };
        output_len += 1;
    }

    return output[0..output_len];
}

/// Reconstructs one validated protocol split tree as disposable client
/// state. Pane-gap and revision preferences are applied by `restoreSaved`.
///
/// ```zig
/// const saved = try Layout.fromClientLayout(tab_layout);
/// ```
pub fn fromClientLayout(encoded: core.ClientTabLayoutView) !Layout {
    var storage: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    var iterator = encoded.nodes();
    var len: usize = 0;
    while (try iterator.next()) |node| : (len += 1) {
        if (len == storage.len) {
            return error.NodeLimitReached;
        }

        storage[len] = node;
    }

    return fromClientLayoutNodes(.{
        .location = encoded.location,
        .focused_pane = encoded.focused_pane,
        .fullscreen = encoded.fullscreen,
        .workspace_active = encoded.workspace_active,
        .nodes = storage[0..len],
    });
}

/// Builds a layout from one tab's pre-order tree, as `clientLayoutNodes`
/// writes it.
///
/// ```zig
/// const layout = try WorkspaceLayout.fromClientLayoutNodes(tab);
/// ```
pub fn fromClientLayoutNodes(tab: core.ClientTabLayout) !Layout {
    var builder: ClientLayoutBuilder = .{
        .nodes = tab.nodes,
    };
    const root = try builder.build(null);
    if (builder.next_index != tab.nodes.len) {
        return error.InvalidClientLayoutTree;
    }

    builder.layout.root = root;
    builder.layout.focused_pane = tab.focused_pane;
    builder.layout.fullscreen = tab.fullscreen;
    if (!builder.layout.contains(tab.focused_pane)) {
        return error.InvalidClientLayoutFocus;
    }

    return builder.layout;
}

pub fn setPaneGaps(self: *Layout, enabled: bool) bool {
    if (self.pane_gaps == enabled) {
        return false;
    }
    self.pane_gaps = enabled;
    self.changed();
    return true;
}

pub fn contains(self: *const Layout, pane_id: core.PaneId) bool {
    return self.findLeaf(pane_id) != null;
}

/// One-based depth-first position used as the pane's disposable display
/// index. Stable runtime ids never leak into the UI.
///
/// ```zig
/// const index = layout.displayIndex(pane_id);
/// ```
pub fn displayIndex(self: *const Layout, pane_id: core.PaneId) ?u16 {
    var storage: [core.max_panes_per_tab]core.PaneId = undefined;
    for (self.orderedPanes(&storage), 1..) |candidate, index| {
        if (candidate == pane_id) {
            return @intCast(index);
        }
    }

    return null;
}

/// Lists leaves in display order, independent of fullscreen and geometry.
///
/// ```zig
/// const panes = layout.orderedPanes(&storage);
/// ```
pub fn orderedPanes(self: *const Layout, output: *[core.max_panes_per_tab]core.PaneId) []const core.PaneId {
    const root = self.root orelse return output[0..0];
    var stack: [layout_support.max_nodes]layout_support.NodeIndex = undefined;
    var stack_len: usize = 1;
    var index: usize = 0;
    stack[0] = root;

    while (stack_len != 0) {
        stack_len -= 1;

        switch (self.nodes[stack[stack_len]].node) {
            .empty => unreachable,
            .leaf => |candidate| {
                output[index] = candidate;
                index += 1;
            },
            .split => |branch| {
                stack[stack_len] = branch.second;
                stack_len += 1;
                stack[stack_len] = branch.first;
                stack_len += 1;
            },
        }
    }

    return output[0..index];
}

pub fn addRoot(self: *Layout, pane_id: core.PaneId) !void {
    if (pane_id == .invalid) {
        return error.InvalidPaneId;
    }
    if (self.root != null) {
        return error.LayoutNotEmpty;
    }
    self.nodes[0] = .{
        .node = .{
            .leaf = pane_id,
        },
    };
    self.root = 0;
    self.focused_pane = pane_id;
    self.pane_count = 1;
    self.fullscreen = false;
    self.changed();
}

/// Rebuilds a disposable layout in the supplied display order, left to
/// right with equal widths, and restores focus only after every pane has
/// its canonical position. Each split leaves its left pane one share of
/// the panes still to place, so the last pair halves what remains. Past
/// ten panes the leading shares clamp at the minimum ratio, and a crowded
/// tab degrades to empty content instead of failing.
///
/// ```zig
/// try layout.restoreDisplayOrder(&.{ first, second, third }, second);
/// ```
pub fn restoreDisplayOrder(self: *Layout, pane_ids: []const core.PaneId, focused_pane: core.PaneId) !void {
    if (pane_ids.len == 0) {
        return error.LayoutEmpty;
    }
    var restored: Layout = .{
        .pane_gaps = self.pane_gaps,
        .metrics = self.metrics,
        .revision = self.revision,
    };
    try restored.addRoot(pane_ids[0]);
    var previous = pane_ids[0];
    for (pane_ids[1..], 1..) |pane_id, index| {
        try restored.split(
            .{
                .existing_pane = previous,
                .new_pane = pane_id,
                .axis = .horizontal,
            },
        );
        restored.setParentRatio(pane_id, layout_support.equalShareRatio(pane_ids.len - index + 1));
        previous = pane_id;
    }
    if (!restored.focusPane(focused_pane)) {
        return error.PaneNotFound;
    }
    self.* = restored;
}

fn setParentRatio(self: *Layout, pane_id: core.PaneId, ratio: u16) void {
    const leaf = self.findLeaf(pane_id) orelse return;
    const parent = self.nodes[leaf].parent orelse return;
    self.nodes[parent].node.split.ratio = ratio;
}

/// Restores an earlier client-owned split tree when it still describes
/// exactly the panes reported by the runtime. Focus remains a separate
/// navigation choice and the current pane-gap preference wins.
///
/// ```zig
/// const restored = layout.restoreSaved(saved, .{ .ids = pane_ids, .focused = focused_pane });
/// ```
pub fn restoreSaved(self: *Layout, saved: Layout, panes: PaneSet) bool {
    if (panes.ids.len == 0 or panes.ids.len != saved.count()) {
        return false;
    }

    for (panes.ids, 0..) |pane_id, index| {
        if (!saved.contains(pane_id)) {
            return false;
        }

        if (std.mem.findScalar(
            core.PaneId,
            panes.ids[0..index],
            pane_id,
        ) != null) {
            return false;
        }
    }

    if (!saved.contains(panes.focused)) {
        return false;
    }

    var restored = saved;
    restored.pane_gaps = self.pane_gaps;
    restored.metrics = self.metrics;
    restored.revision = self.revision;
    restored.focused_pane = panes.focused;
    restored.changed();
    self.* = restored;

    return true;
}

pub fn splitFocused(self: *Layout, pane_id: core.PaneId, axis: layout_support.Axis) !void {
    const focused_pane = self.focused() orelse return error.LayoutEmpty;
    try self.split(
        .{
            .existing_pane = focused_pane,
            .new_pane = pane_id,
            .axis = axis,
        },
    );
}

/// Replaces one leaf with a split containing the existing and new panes.
///
/// ```zig
/// try layout.split(.{ .existing_pane = first, .new_pane = second, .axis = .horizontal });
/// ```
pub fn split(self: *Layout, request: SplitRequest) !void {
    if (request.new_pane == .invalid) {
        return error.InvalidPaneId;
    }

    if (self.contains(request.new_pane)) {
        return error.DuplicatePane;
    }

    if (self.pane_count == core.max_panes_per_tab) {
        return error.PaneLimitReached;
    }

    const target = self.findLeaf(request.existing_pane) orelse return error.PaneNotFound;

    const first = self.allocateNode() orelse return error.NodeLimitReached;
    errdefer self.nodes[first] = .{};
    self.nodes[first].node = .{
        .leaf = .invalid,
    };
    const second = self.allocateNode() orelse return error.NodeLimitReached;
    const parent = self.nodes[target].parent;
    self.nodes[first] = self.nodes[target];
    self.nodes[first].parent = target;
    self.nodes[second] = .{
        .parent = target,
        .node = .{
            .leaf = request.new_pane,
        },
    };
    self.nodes[target] = .{
        .parent = parent,
        .node = .{
            .split = .{
                .axis = request.axis,
                .first = first,
                .second = second,
            },
        },
    };
    self.focused_pane = request.new_pane;
    self.pane_count += 1;
    self.changed();
}

pub fn remove(self: *Layout, pane_id: core.PaneId) bool {
    const leaf = self.findLeaf(pane_id) orelse return false;
    const parent = self.nodes[leaf].parent orelse {
        self.nodes[leaf] = .{};
        self.root = null;
        self.focused_pane = .invalid;
        self.pane_count = 0;
        self.fullscreen = false;
        self.changed();
        return true;
    };
    const branch = self.nodes[parent].node.split;
    const sibling = if (branch.first == leaf) branch.second else branch.first;
    const grandparent = self.nodes[parent].parent;
    const replacement = self.nodes[sibling];
    self.nodes[parent] = replacement;
    self.nodes[parent].parent = grandparent;
    switch (replacement.node) {
        .split => |children| {
            self.nodes[children.first].parent = parent;
            self.nodes[children.second].parent = parent;
        },
        else => {},
    }
    self.nodes[leaf] = .{};
    self.nodes[sibling] = .{};
    self.pane_count -= 1;
    if (self.focused_pane == pane_id) {
        self.focused_pane = self.firstLeaf(parent).?;
    }
    self.changed();
    return true;
}

pub fn focusPane(self: *Layout, pane_id: core.PaneId) bool {
    if (!self.contains(pane_id)) {
        return false;
    }
    if (self.focused_pane == pane_id) {
        return true;
    }
    self.focused_pane = pane_id;
    self.changed();
    return true;
}

/// Fullscreen follows the border tabs horizontally without changing the
/// split tree. Tiled panes retain spatial navigation.
///
/// ```zig
/// const focused = layout.focusDirection(.right, area);
/// ```
pub fn focusDirection(self: *Layout, direction: layout_support.Direction, area: cellgrid.Rect) ?core.PaneId {
    const current_id = self.focused() orelse return null;
    const candidate = if (self.fullscreen)
        self.fullscreenFocusTarget(direction)
    else spatial: {
        var geometry: LayoutSnapshot = .{};
        self.snapshotTiled(area, &geometry);
        break :spatial geometry.focusTarget(current_id, direction);
    };

    if (candidate) |pane_id| {
        _ = self.focusPane(pane_id);
    }

    return candidate;
}

fn fullscreenFocusTarget(self: *const Layout, direction: layout_support.Direction) ?core.PaneId {
    if (direction == .up or direction == .down) {
        return null;
    }

    var storage: [core.max_panes_per_tab]core.PaneId = undefined;
    const panes = self.orderedPanes(&storage);

    for (panes, 0..) |pane_id, index| {
        if (pane_id != self.focused_pane) {
            continue;
        }

        return switch (direction) {
            .left => if (index > 0) panes[index - 1] else null,
            .right => if (index + 1 < panes.len) panes[index + 1] else null,
            .up, .down => unreachable,
        };
    }

    return null;
}

/// Moves the nearest split edge in `direction` by five percent. If the
/// requested edge is outside the tab, the nearest opposite edge moves in
/// that direction instead. Ratios stay bounded and every leaf retains at
/// least one content cell along the resized axis.
pub fn resizeFocused(self: *Layout, direction: layout_support.Direction, area: cellgrid.Rect) bool {
    const leaf = self.findLeaf(self.focused_pane) orelse return false;
    const target = self.resizeSplit(leaf, direction) orelse return false;
    const branch = self.nodes[target].node.split;
    const previous = branch.ratio;
    const adjusted = switch (direction) {
        .left, .up => previous -| layout_support.resize_step,
        .right, .down => previous +| layout_support.resize_step,
    };
    const candidate = std.math.clamp(
        adjusted,
        core.min_client_layout_ratio,
        core.max_client_layout_ratio,
    );
    if (candidate == previous) {
        return false;
    }
    const target_area = self.nodeArea(target, area);
    if (!self.ratioFits(
        branch,
        .{
            .area = target_area,
            .ratio = candidate,
        },
    )) {
        return false;
    }

    self.nodes[target].node.split.ratio = candidate;
    self.changed();
    return true;
}

pub fn toggleFullscreen(self: *Layout) bool {
    if (self.pane_count == 0) {
        return false;
    }

    self.fullscreen = !self.fullscreen;
    self.changed();
    return true;
}

/// Reports whether the target pane can be split inside the available area.
///
/// ```zig
/// const allowed = layout.canSplit(.{ .pane_id = pane_id, .axis = .horizontal }, area);
/// ```
pub fn canSplit(self: *const Layout, target: SplitTarget, area: cellgrid.Rect) bool {
    var geometry: LayoutSnapshot = .{};
    self.snapshot(area, &geometry);

    return geometry.prospectiveSplit(target, self.pane_count) != null;
}

/// Computes the target split geometry without mutating the layout.
///
/// ```zig
/// const split = layout.prospectiveSplit(.{ .pane_id = pane_id, .axis = .horizontal }, area);
/// ```
pub fn prospectiveSplit(self: *const Layout, target: SplitTarget, area: cellgrid.Rect) ?ProspectiveSplit {
    var geometry: LayoutSnapshot = .{};
    self.snapshot(area, &geometry);

    return geometry.prospectiveSplit(target, self.pane_count);
}

/// A fullscreen pane keeps its border and labels regardless of pane count.
/// Example: `layout.snapshot(area, &geometry);`.
pub fn snapshot(self: *const Layout, area: cellgrid.Rect, output: *LayoutSnapshot) void {
    if (!self.fullscreen) {
        return self.snapshotTiled(area, output);
    }
    output.reset(
        .{
            .area = area,
            .revision = self.revision,
            .pane_gaps = self.pane_gaps,
            .metrics = self.metrics,
        },
    );
    const pane_id = self.focused() orelse return;
    output.append(
        .{
            .pane_id = pane_id,
            .outer = area,
            .content = area.inner(self.metrics.border),
            .focused = true,
            .display_index = self.displayIndex(pane_id) orelse 1,
        },
    );
}

fn snapshotTiled(self: *const Layout, area: cellgrid.Rect, output: *LayoutSnapshot) void {
    output.reset(
        .{
            .area = area,
            .revision = self.revision,
            .pane_gaps = self.pane_gaps,
            .metrics = self.metrics,
        },
    );
    const root = self.root orelse return;
    const Pending = struct { node: layout_support.NodeIndex, area: cellgrid.Rect };
    var stack: [layout_support.max_nodes]Pending = undefined;
    var stack_len: usize = 1;
    var display_index: u16 = 0;
    stack[0] = .{
        .node = root,
        .area = area,
    };
    while (stack_len != 0) {
        stack_len -= 1;
        const pending = stack[stack_len];
        switch (self.nodes[pending.node].node) {
            .empty => unreachable,
            .leaf => |pane_id| {
                display_index += 1;
                output.append(
                    .{
                        .pane_id = pane_id,
                        .outer = pending.area,
                        .content = if (self.hasBorders())
                            pending.area.inner(self.metrics.border)
                        else
                            pending.area,
                        .focused = pane_id == self.focused_pane,
                        .display_index = display_index,
                    },
                );
            },
            .split => |branch| {
                const first, const second = layout_support.splitArea(
                    .{
                        .area = pending.area,
                        .axis = branch.axis,
                        .ratio = branch.ratio,
                        .gap = self.metrics.gutter(self.pane_gaps),
                    },
                );
                stack[stack_len] = .{
                    .node = branch.second,
                    .area = second,
                };
                stack_len += 1;
                stack[stack_len] = .{
                    .node = branch.first,
                    .area = first,
                };
                stack_len += 1;
            },
        }
    }
}

pub fn views(self: *const Layout, area: cellgrid.Rect, output: *[core.max_panes_per_tab]View) []View {
    var snapshot_output: LayoutSnapshot = .{};
    self.snapshot(area, &snapshot_output);
    @memcpy(output[0..snapshot_output.len], snapshot_output.views());
    return output[0..snapshot_output.len];
}

fn resizeSplit(self: *const Layout, leaf: layout_support.NodeIndex, direction: layout_support.Direction) ?layout_support.NodeIndex {
    const target_axis: layout_support.Axis = switch (direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };
    var fallback: ?layout_support.NodeIndex = null;
    var child = leaf;
    while (self.nodes[child].parent) |parent| {
        const branch = self.nodes[parent].node.split;
        if (branch.axis == target_axis) {
            const child_is_first = branch.first == child;
            const requested_edge = switch (direction) {
                .left, .up => !child_is_first,
                .right, .down => child_is_first,
            };
            if (requested_edge) {
                return parent;
            }
            if (fallback == null) {
                fallback = parent;
            }
        }
        child = parent;
    }
    return fallback;
}

fn nodeArea(self: *const Layout, target: layout_support.NodeIndex, area: cellgrid.Rect) cellgrid.Rect {
    var path: [layout_support.max_nodes]layout_support.NodeIndex = undefined;
    var path_len: usize = 0;
    var current = target;
    while (self.nodes[current].parent) |parent| {
        path[path_len] = current;
        path_len += 1;
        current = parent;
    }
    var current_area = area;
    while (path_len != 0) {
        path_len -= 1;
        const child = path[path_len];
        const branch = self.nodes[current].node.split;
        const first, const second = layout_support.splitArea(
            .{
                .area = current_area,
                .axis = branch.axis,
                .ratio = branch.ratio,
                .gap = self.metrics.gutter(self.pane_gaps),
            },
        );
        current_area = if (branch.first == child) first else second;
        current = child;
    }
    return current_area;
}

fn ratioFits(self: *const Layout, branch: Split, candidate: RatioCandidate) bool {
    const first, const second = layout_support.splitArea(
        .{
            .area = candidate.area,
            .axis = branch.axis,
            .ratio = candidate.ratio,
            .gap = self.metrics.gutter(self.pane_gaps),
        },
    );
    const first_extent = layout_support.extent(first, branch.axis);
    const second_extent = layout_support.extent(second, branch.axis);

    return first_extent >= self.minimumExtent(branch.first, branch.axis) and
        second_extent >= self.minimumExtent(branch.second, branch.axis);
}

fn minimumExtent(self: *const Layout, node_index: layout_support.NodeIndex, axis: layout_support.Axis) u16 {
    return switch (self.nodes[node_index].node) {
        .empty => 0,
        .leaf => self.metrics.minimumPaneExtent(),
        .split => |branch| {
            const first = self.minimumExtent(branch.first, axis);
            const second = self.minimumExtent(branch.second, axis);
            if (branch.axis == axis) {
                return first +| self.metrics.gutter(self.pane_gaps) +| second;
            }
            return @max(first, second);
        },
    };
}

fn allocateNode(self: *Layout) ?layout_support.NodeIndex {
    for (&self.nodes, 0..) |*slot, index| {
        if (slot.node == .empty) {
            return @intCast(index);
        }
    }
    return null;
}

fn findLeaf(self: *const Layout, pane_id: core.PaneId) ?layout_support.NodeIndex {
    for (self.nodes, 0..) |slot, index| switch (slot.node) {
        .leaf => |candidate| if (candidate == pane_id) return @intCast(index),
        else => {},
    };
    return null;
}

fn firstLeaf(self: *const Layout, start: layout_support.NodeIndex) ?core.PaneId {
    var current = start;
    while (true) switch (self.nodes[current].node) {
        .empty => return null,
        .leaf => |pane_id| return pane_id,
        .split => |branch| current = branch.first,
    };
}

fn changed(self: *Layout) void {
    self.revision +%= 1;
    if (self.revision == 0) {
        self.revision = 1;
    }
}

