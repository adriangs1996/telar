const layout_support = @import("layout_support.zig");
const Slot = @import("Slot.zig");
const PaneIdType = @import("telar-core").PaneId;
const Metrics = @import("Metrics.zig");
const std = @import("std");
const max_client_layout_nodes_module = @import("telar-core").max_client_layout_nodes;
const ClientLayoutNodeType = @import("telar-core").ClientLayoutNode;
const ClientTabLayoutViewType = @import("telar-core").ClientTabLayoutView;
const ClientLayoutBuilder = @import("ClientLayoutBuilder.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const PaneSet = @import("PaneSet.zig");
const SplitRequest = @import("SplitRequest.zig");
const RectType = @import("telar-core").Rect;
const LayoutSnapshot = @import("LayoutSnapshot.zig");
const min_client_layout_ratio = @import("telar-core").min_client_layout_ratio;
const max_client_layout_ratio = @import("telar-core").max_client_layout_ratio;
const SplitTarget = @import("SplitTarget.zig");
const ProspectiveSplit = @import("ProspectiveSplit.zig");
const View = @import("LayoutView.zig");
const Split = @import("Split.zig");
const RatioCandidate = @import("RatioCandidate.zig");
const Layout = @This();

nodes: [layout_support.max_nodes]Slot = [_]Slot{.{}} ** layout_support.max_nodes,
root: ?layout_support.NodeIndex = null,
focused_pane: PaneIdType = .invalid,
pane_count: u8 = 0,
fullscreen: bool = false,
pane_gaps: bool = true,
metrics: Metrics = .{},
revision: u64 = 1,

/// Installs presentation measurements without changing topology or ratios.
/// Example: `_ = layout.setMetrics(.{ .border = 0, .gap = 0 });`.
pub fn setMetrics(layout: *Layout, metrics: Metrics) bool {
    if (std.meta.eql(layout.metrics, metrics)) {
        return false;
    }

    layout.metrics = metrics;
    layout.changed();
    return true;
}

pub fn count(layout: *const Layout) usize {
    return layout.pane_count;
}

pub fn focused(layout: *const Layout) ?PaneIdType {
    return if (layout.focused_pane == .invalid) null else layout.focused_pane;
}

pub fn currentRevision(layout: *const Layout) u64 {
    return layout.revision;
}

pub fn isFullscreen(layout: *const Layout) bool {
    return layout.fullscreen;
}

/// Fullscreen keeps its label border even when the tab has only one pane.
/// Example: `if (layout.hasBorders()) drawPaneBorder();`.
pub fn hasBorders(layout: *const Layout) bool {
    return layout.metrics.border != 0 and (layout.fullscreen or layout.pane_count > 1);
}

/// Writes this split tree in the protocol's pre-order representation.
///
/// ```zig
/// var nodes: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined;
/// const encoded = layout.clientLayoutNodes(&nodes);
/// ```
pub fn clientLayoutNodes(layout: *const Layout, output: *[max_client_layout_nodes_module]ClientLayoutNodeType) []const ClientLayoutNodeType {
    const root = layout.root orelse return output[0..0];
    var stack: [layout_support.max_nodes]layout_support.NodeIndex = undefined;
    var stack_len: usize = 1;
    var output_len: usize = 0;
    stack[0] = root;
    while (stack_len != 0) {
        stack_len -= 1;
        const node = layout.nodes[stack[stack_len]].node;
        output[output_len] = switch (node) {
            .empty => unreachable,
            .leaf => |pane_id| .{ .pane = pane_id },
            .split => |branch| encoded: {
                stack[stack_len] = branch.second;
                stack_len += 1;
                stack[stack_len] = branch.first;
                stack_len += 1;
                break :encoded .{ .split = .{
                    .axis = switch (branch.axis) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .ratio = branch.ratio,
                } };
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
pub fn fromClientLayout(encoded: ClientTabLayoutViewType) !Layout {
    var iterator = encoded.nodes();
    var builder: ClientLayoutBuilder = .{ .iterator = &iterator };
    const root = try builder.build(null);
    if (try iterator.next() != null) {
        return error.InvalidClientLayoutTree;
    }

    builder.layout.root = root;
    builder.layout.focused_pane = encoded.focused_pane;
    builder.layout.fullscreen = encoded.fullscreen;
    if (!builder.layout.contains(encoded.focused_pane)) {
        return error.InvalidClientLayoutFocus;
    }

    return builder.layout;
}

pub fn setPaneGaps(layout: *Layout, enabled: bool) bool {
    if (layout.pane_gaps == enabled) {
        return false;
    }
    layout.pane_gaps = enabled;
    layout.changed();
    return true;
}

pub fn contains(layout: *const Layout, pane_id: PaneIdType) bool {
    return layout.findLeaf(pane_id) != null;
}

/// One-based depth-first position used as the pane's disposable display
/// index. Stable runtime ids never leak into the UI.
///
/// ```zig
/// const index = layout.displayIndex(pane_id);
/// ```
pub fn displayIndex(layout: *const Layout, pane_id: PaneIdType) ?u16 {
    var storage: [max_panes_per_tab]PaneIdType = undefined;
    for (layout.orderedPanes(&storage), 1..) |candidate, index| {
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
pub fn orderedPanes(layout: *const Layout, output: *[max_panes_per_tab]PaneIdType) []const PaneIdType {
    const root = layout.root orelse return output[0..0];
    var stack: [layout_support.max_nodes]layout_support.NodeIndex = undefined;
    var stack_len: usize = 1;
    var index: usize = 0;
    stack[0] = root;

    while (stack_len != 0) {
        stack_len -= 1;

        switch (layout.nodes[stack[stack_len]].node) {
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

pub fn addRoot(layout: *Layout, pane_id: PaneIdType) !void {
    if (pane_id == .invalid) {
        return error.InvalidPaneId;
    }
    if (layout.root != null) {
        return error.LayoutNotEmpty;
    }
    layout.nodes[0] = .{ .node = .{ .leaf = pane_id } };
    layout.root = 0;
    layout.focused_pane = pane_id;
    layout.pane_count = 1;
    layout.fullscreen = false;
    layout.changed();
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
pub fn restoreDisplayOrder(layout: *Layout, pane_ids: []const PaneIdType, focused_pane: PaneIdType) !void {
    if (pane_ids.len == 0) {
        return error.LayoutEmpty;
    }
    var restored: Layout = .{
        .pane_gaps = layout.pane_gaps,
        .metrics = layout.metrics,
        .revision = layout.revision,
    };
    try restored.addRoot(pane_ids[0]);
    var previous = pane_ids[0];
    for (pane_ids[1..], 1..) |pane_id, index| {
        try restored.split(.{
            .existing_pane = previous,
            .new_pane = pane_id,
            .axis = .horizontal,
        });
        restored.setParentRatio(pane_id, layout_support.equalShareRatio(pane_ids.len - index + 1));
        previous = pane_id;
    }
    if (!restored.focusPane(focused_pane)) {
        return error.PaneNotFound;
    }
    layout.* = restored;
}

fn setParentRatio(layout: *Layout, pane_id: PaneIdType, ratio: u16) void {
    const leaf = layout.findLeaf(pane_id) orelse return;
    const parent = layout.nodes[leaf].parent orelse return;
    layout.nodes[parent].node.split.ratio = ratio;
}

/// Restores an earlier client-owned split tree when it still describes
/// exactly the panes reported by the runtime. Focus remains a separate
/// navigation choice and the current pane-gap preference wins.
///
/// ```zig
/// const restored = layout.restoreSaved(saved, .{ .ids = pane_ids, .focused = focused_pane });
/// ```
pub fn restoreSaved(layout: *Layout, saved: Layout, panes: PaneSet) bool {
    if (panes.ids.len == 0 or panes.ids.len != saved.count()) {
        return false;
    }

    for (panes.ids, 0..) |pane_id, index| {
        if (!saved.contains(pane_id)) {
            return false;
        }

        if (std.mem.findScalar(PaneIdType, panes.ids[0..index], pane_id) != null) {
            return false;
        }
    }

    if (!saved.contains(panes.focused)) {
        return false;
    }

    var restored = saved;
    restored.pane_gaps = layout.pane_gaps;
    restored.metrics = layout.metrics;
    restored.revision = layout.revision;
    restored.focused_pane = panes.focused;
    restored.changed();
    layout.* = restored;

    return true;
}

pub fn splitFocused(layout: *Layout, pane_id: PaneIdType, axis: layout_support.Axis) !void {
    const focused_pane = layout.focused() orelse return error.LayoutEmpty;
    try layout.split(.{
        .existing_pane = focused_pane,
        .new_pane = pane_id,
        .axis = axis,
    });
}

/// Replaces one leaf with a split containing the existing and new panes.
///
/// ```zig
/// try layout.split(.{ .existing_pane = first, .new_pane = second, .axis = .horizontal });
/// ```
pub fn split(layout: *Layout, request: SplitRequest) !void {
    if (request.new_pane == .invalid) {
        return error.InvalidPaneId;
    }

    if (layout.contains(request.new_pane)) {
        return error.DuplicatePane;
    }

    if (layout.pane_count == max_panes_per_tab) {
        return error.PaneLimitReached;
    }

    const target = layout.findLeaf(request.existing_pane) orelse return error.PaneNotFound;

    const first = layout.allocateNode() orelse return error.NodeLimitReached;
    errdefer layout.nodes[first] = .{};
    layout.nodes[first].node = .{ .leaf = .invalid };
    const second = layout.allocateNode() orelse return error.NodeLimitReached;
    const parent = layout.nodes[target].parent;
    layout.nodes[first] = .{ .parent = target, .node = .{ .leaf = request.existing_pane } };
    layout.nodes[second] = .{ .parent = target, .node = .{ .leaf = request.new_pane } };
    layout.nodes[target] = .{
        .parent = parent,
        .node = .{ .split = .{
            .axis = request.axis,
            .first = first,
            .second = second,
        } },
    };
    layout.focused_pane = request.new_pane;
    layout.pane_count += 1;
    layout.changed();
}

pub fn remove(layout: *Layout, pane_id: PaneIdType) bool {
    const leaf = layout.findLeaf(pane_id) orelse return false;
    const parent = layout.nodes[leaf].parent orelse {
        layout.nodes[leaf] = .{};
        layout.root = null;
        layout.focused_pane = .invalid;
        layout.pane_count = 0;
        layout.fullscreen = false;
        layout.changed();
        return true;
    };
    const branch = layout.nodes[parent].node.split;
    const sibling = if (branch.first == leaf) branch.second else branch.first;
    const grandparent = layout.nodes[parent].parent;
    const replacement = layout.nodes[sibling].node;
    layout.nodes[parent] = .{ .parent = grandparent, .node = replacement };
    switch (replacement) {
        .split => |children| {
            layout.nodes[children.first].parent = parent;
            layout.nodes[children.second].parent = parent;
        },
        else => {},
    }
    layout.nodes[leaf] = .{};
    layout.nodes[sibling] = .{};
    layout.pane_count -= 1;
    if (layout.focused_pane == pane_id) {
        layout.focused_pane = layout.firstLeaf(parent).?;
    }
    layout.changed();
    return true;
}

pub fn focusPane(layout: *Layout, pane_id: PaneIdType) bool {
    if (!layout.contains(pane_id)) {
        return false;
    }
    if (layout.focused_pane == pane_id) {
        return true;
    }
    layout.focused_pane = pane_id;
    layout.changed();
    return true;
}

/// Fullscreen follows the border tabs horizontally without changing the
/// split tree. Tiled panes retain spatial navigation.
///
/// ```zig
/// const focused = layout.focusDirection(.right, area);
/// ```
pub fn focusDirection(layout: *Layout, direction: layout_support.Direction, area: RectType) ?PaneIdType {
    const current_id = layout.focused() orelse return null;
    const candidate = if (layout.fullscreen)
        layout.fullscreenFocusTarget(direction)
    else spatial: {
        var geometry: LayoutSnapshot = .{};
        layout.snapshotTiled(area, &geometry);
        break :spatial geometry.focusTarget(current_id, direction);
    };

    if (candidate) |pane_id| {
        _ = layout.focusPane(pane_id);
    }

    return candidate;
}

fn fullscreenFocusTarget(layout: *const Layout, direction: layout_support.Direction) ?PaneIdType {
    if (direction == .up or direction == .down) {
        return null;
    }

    var storage: [max_panes_per_tab]PaneIdType = undefined;
    const panes = layout.orderedPanes(&storage);

    for (panes, 0..) |pane_id, index| {
        if (pane_id != layout.focused_pane) {
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
pub fn resizeFocused(layout: *Layout, direction: layout_support.Direction, area: RectType) bool {
    const leaf = layout.findLeaf(layout.focused_pane) orelse return false;
    const target = layout.resizeSplit(leaf, direction) orelse return false;
    const branch = layout.nodes[target].node.split;
    const previous = branch.ratio;
    const adjusted = switch (direction) {
        .left, .up => previous -| layout_support.resize_step,
        .right, .down => previous +| layout_support.resize_step,
    };
    const candidate = std.math.clamp(
        adjusted,
        min_client_layout_ratio,
        max_client_layout_ratio,
    );
    if (candidate == previous) {
        return false;
    }
    const target_area = layout.nodeArea(target, area);
    if (!layout.ratioFits(branch, .{ .area = target_area, .ratio = candidate })) {
        return false;
    }

    layout.nodes[target].node.split.ratio = candidate;
    layout.changed();
    return true;
}

pub fn toggleFullscreen(layout: *Layout) bool {
    if (layout.pane_count == 0) {
        return false;
    }

    layout.fullscreen = !layout.fullscreen;
    layout.changed();
    return true;
}

/// Reports whether the target pane can be split inside the available area.
///
/// ```zig
/// const allowed = layout.canSplit(.{ .pane_id = pane_id, .axis = .horizontal }, area);
/// ```
pub fn canSplit(layout: *const Layout, target: SplitTarget, area: RectType) bool {
    var geometry: LayoutSnapshot = .{};
    layout.snapshot(area, &geometry);

    return geometry.prospectiveSplit(target, layout.pane_count) != null;
}

/// Computes the target split geometry without mutating the layout.
///
/// ```zig
/// const split = layout.prospectiveSplit(.{ .pane_id = pane_id, .axis = .horizontal }, area);
/// ```
pub fn prospectiveSplit(layout: *const Layout, target: SplitTarget, area: RectType) ?ProspectiveSplit {
    var geometry: LayoutSnapshot = .{};
    layout.snapshot(area, &geometry);

    return geometry.prospectiveSplit(target, layout.pane_count);
}

/// A fullscreen pane keeps its border and labels regardless of pane count.
/// Example: `layout.snapshot(area, &geometry);`.
pub fn snapshot(layout: *const Layout, area: RectType, output: *LayoutSnapshot) void {
    if (!layout.fullscreen) {
        return layout.snapshotTiled(area, output);
    }
    output.reset(.{ .area = area, .revision = layout.revision, .pane_gaps = layout.pane_gaps, .metrics = layout.metrics });
    const pane_id = layout.focused() orelse return;
    output.append(.{
        .pane_id = pane_id,
        .outer = area,
        .content = area.inner(layout.metrics.border),
        .focused = true,
        .display_index = layout.displayIndex(pane_id) orelse 1,
    });
}

fn snapshotTiled(layout: *const Layout, area: RectType, output: *LayoutSnapshot) void {
    output.reset(.{ .area = area, .revision = layout.revision, .pane_gaps = layout.pane_gaps, .metrics = layout.metrics });
    const root = layout.root orelse return;
    const Pending = struct { node: layout_support.NodeIndex, area: RectType };
    var stack: [layout_support.max_nodes]Pending = undefined;
    var stack_len: usize = 1;
    var display_index: u16 = 0;
    stack[0] = .{ .node = root, .area = area };
    while (stack_len != 0) {
        stack_len -= 1;
        const pending = stack[stack_len];
        switch (layout.nodes[pending.node].node) {
            .empty => unreachable,
            .leaf => |pane_id| {
                display_index += 1;
                output.append(.{
                    .pane_id = pane_id,
                    .outer = pending.area,
                    .content = if (layout.hasBorders())
                        pending.area.inner(layout.metrics.border)
                    else
                        pending.area,
                    .focused = pane_id == layout.focused_pane,
                    .display_index = display_index,
                });
            },
            .split => |branch| {
                const first, const second = layout_support.splitArea(.{
                    .area = pending.area,
                    .axis = branch.axis,
                    .ratio = branch.ratio,
                    .gap = layout.metrics.gutter(layout.pane_gaps),
                });
                stack[stack_len] = .{ .node = branch.second, .area = second };
                stack_len += 1;
                stack[stack_len] = .{ .node = branch.first, .area = first };
                stack_len += 1;
            },
        }
    }
}

pub fn views(layout: *const Layout, area: RectType, output: *[max_panes_per_tab]View) []View {
    var snapshot_output: LayoutSnapshot = .{};
    layout.snapshot(area, &snapshot_output);
    @memcpy(output[0..snapshot_output.len], snapshot_output.views());
    return output[0..snapshot_output.len];
}

fn resizeSplit(layout: *const Layout, leaf: layout_support.NodeIndex, direction: layout_support.Direction) ?layout_support.NodeIndex {
    const target_axis: layout_support.Axis = switch (direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };
    var fallback: ?layout_support.NodeIndex = null;
    var child = leaf;
    while (layout.nodes[child].parent) |parent| {
        const branch = layout.nodes[parent].node.split;
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

fn nodeArea(layout: *const Layout, target: layout_support.NodeIndex, area: RectType) RectType {
    var path: [layout_support.max_nodes]layout_support.NodeIndex = undefined;
    var path_len: usize = 0;
    var current = target;
    while (layout.nodes[current].parent) |parent| {
        path[path_len] = current;
        path_len += 1;
        current = parent;
    }
    var current_area = area;
    while (path_len != 0) {
        path_len -= 1;
        const child = path[path_len];
        const branch = layout.nodes[current].node.split;
        const first, const second = layout_support.splitArea(.{
            .area = current_area,
            .axis = branch.axis,
            .ratio = branch.ratio,
            .gap = layout.metrics.gutter(layout.pane_gaps),
        });
        current_area = if (branch.first == child) first else second;
        current = child;
    }
    return current_area;
}

fn ratioFits(layout: *const Layout, branch: Split, candidate: RatioCandidate) bool {
    const first, const second = layout_support.splitArea(.{
        .area = candidate.area,
        .axis = branch.axis,
        .ratio = candidate.ratio,
        .gap = layout.metrics.gutter(layout.pane_gaps),
    });
    const first_extent = layout_support.extent(first, branch.axis);
    const second_extent = layout_support.extent(second, branch.axis);

    return first_extent >= layout.minimumExtent(branch.first, branch.axis) and
        second_extent >= layout.minimumExtent(branch.second, branch.axis);
}

fn minimumExtent(layout: *const Layout, node_index: layout_support.NodeIndex, axis: layout_support.Axis) u16 {
    return switch (layout.nodes[node_index].node) {
        .empty => 0,
        .leaf => layout.metrics.minimumPaneExtent(),
        .split => |branch| {
            const first = layout.minimumExtent(branch.first, axis);
            const second = layout.minimumExtent(branch.second, axis);
            if (branch.axis == axis) {
                return first +| layout.metrics.gutter(layout.pane_gaps) +| second;
            }
            return @max(first, second);
        },
    };
}

fn allocateNode(layout: *Layout) ?layout_support.NodeIndex {
    for (&layout.nodes, 0..) |*slot, index| {
        if (slot.node == .empty) {
            return @intCast(index);
        }
    }
    return null;
}

fn findLeaf(layout: *const Layout, pane_id: PaneIdType) ?layout_support.NodeIndex {
    for (layout.nodes, 0..) |slot, index| switch (slot.node) {
        .leaf => |candidate| if (candidate == pane_id) return @intCast(index),
        else => {},
    };
    return null;
}

fn firstLeaf(layout: *const Layout, start: layout_support.NodeIndex) ?PaneIdType {
    var current = start;
    while (true) switch (layout.nodes[current].node) {
        .empty => return null,
        .leaf => |pane_id| return pane_id,
        .split => |branch| current = branch.first,
    };
}

fn changed(layout: *Layout) void {
    layout.revision +%= 1;
    if (layout.revision == 0) {
        layout.revision = 1;
    }
}
