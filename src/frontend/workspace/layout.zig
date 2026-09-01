//! Disposable pane layout owned by the client.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;
const ui = core.ui;

pub const max_panes = schema.max_panes_per_tab;
const max_nodes = max_panes * 2 - 1;
const NodeIndex = u8;
const index_capacity = max_panes * 2;
const ViewIndex = core.fixed_index.SlotIndex(index_capacity);
const ratio_scale: u16 = schema.client_layout_ratio_scale;
const default_split_ratio: u16 = ratio_scale / 2;
const minimum_split_ratio: u16 = schema.min_client_layout_ratio;
const maximum_split_ratio: u16 = schema.max_client_layout_ratio;
pub const resize_step: u16 = ratio_scale / 20;

pub const Axis = enum {
    /// Children occupy the left and right halves.
    horizontal,
    /// Children occupy the top and bottom halves.
    vertical,
};

pub const Direction = enum {
    left,
    right,
    up,
    down,
};

const Split = struct {
    axis: Axis,
    ratio: u16 = default_split_ratio,
    first: NodeIndex,
    second: NodeIndex,
};

const Node = union(enum) {
    empty,
    leaf: schema.PaneId,
    split: Split,
};

const Slot = struct {
    parent: ?NodeIndex = null,
    node: Node = .empty,
};

pub const View = struct {
    pane_id: schema.PaneId,
    outer: ui.Rect,
    content: ui.Rect,
    focused: bool,
};

pub const ProspectiveSplit = struct {
    existing_content: ui.Rect,
    new_content: ui.Rect,
};

/// Immutable geometry consumed by every subsystem during a frame. Building it
/// is O(panes); pane lookup is bounded open addressing with no allocations.
pub const Snapshot = struct {
    area: ui.Rect = .{},
    revision: u64 = 0,
    pane_gaps: bool = true,
    storage: [max_panes]View = undefined,
    len: u8 = 0,
    index: ViewIndex = .{},

    pub fn views(snapshot: *const Snapshot) []const View {
        return snapshot.storage[0..snapshot.len];
    }

    pub fn find(snapshot: *const Snapshot, pane_id: schema.PaneId) ?View {
        if (pane_id == .invalid) return null;
        const view_index = snapshot.index.get(schema.id.raw(pane_id)) orelse return null;
        return snapshot.storage[view_index];
    }

    pub fn prospectiveSplit(
        snapshot: *const Snapshot,
        pane_id: schema.PaneId,
        axis: Axis,
        pane_count: usize,
    ) ?ProspectiveSplit {
        if (pane_count == max_panes) return null;
        const view = snapshot.find(pane_id) orelse return null;
        const minimum_split_extent: u16 = 6 + @as(u16, @intFromBool(snapshot.pane_gaps));
        const enough_space = switch (axis) {
            .horizontal => view.outer.w >= minimum_split_extent and view.outer.h >= 3,
            .vertical => view.outer.w >= 3 and view.outer.h >= minimum_split_extent,
        };
        if (!enough_space) return null;
        const first, const second = splitArea(
            view.outer,
            axis,
            default_split_ratio,
            snapshot.pane_gaps,
        );
        return .{
            .existing_content = borderedContent(first),
            .new_content = borderedContent(second),
        };
    }

    pub fn focusTarget(
        snapshot: *const Snapshot,
        current_id: schema.PaneId,
        direction: Direction,
    ) ?schema.PaneId {
        const source = snapshot.find(current_id) orelse return null;
        var candidate: ?schema.PaneId = null;
        var best_score: u64 = std.math.maxInt(u64);
        const source_x = center(source.outer.x, source.outer.w);
        const source_y = center(source.outer.y, source.outer.h);
        for (snapshot.views()) |view| {
            if (view.pane_id == current_id) continue;
            const candidate_x = center(view.outer.x, view.outer.w);
            const candidate_y = center(view.outer.y, view.outer.h);
            const source_left: u32 = source.outer.x;
            const source_top: u32 = source.outer.y;
            const source_right = source_left + source.outer.w;
            const source_bottom = source_top + source.outer.h;
            const candidate_left: u32 = view.outer.x;
            const candidate_top: u32 = view.outer.y;
            const candidate_right = candidate_left + view.outer.w;
            const candidate_bottom = candidate_top + view.outer.h;
            const primary, const secondary, const forward = switch (direction) {
                .left => .{
                    source_left -| candidate_right,
                    distance(source_y, candidate_y) / 2,
                    candidate_right <= source_left,
                },
                .right => .{
                    candidate_left -| source_right,
                    distance(source_y, candidate_y) / 2,
                    candidate_left >= source_right,
                },
                .up => .{
                    source_top -| candidate_bottom,
                    distance(source_x, candidate_x) / 2,
                    candidate_bottom <= source_top,
                },
                .down => .{
                    candidate_top -| source_bottom,
                    distance(source_x, candidate_x) / 2,
                    candidate_top >= source_bottom,
                },
            };
            if (!forward) continue;
            const score = @as(u64, primary) * 65536 + secondary;
            if (score < best_score) {
                best_score = score;
                candidate = view.pane_id;
            }
        }
        return candidate;
    }

    fn reset(snapshot: *Snapshot, area: ui.Rect, revision: u64, pane_gaps: bool) void {
        snapshot.area = area;
        snapshot.revision = revision;
        snapshot.pane_gaps = pane_gaps;
        snapshot.len = 0;
        snapshot.index.reset();
    }

    fn append(snapshot: *Snapshot, view: View) void {
        const view_index = snapshot.len;
        snapshot.storage[view_index] = view;
        snapshot.len += 1;
        snapshot.index.put(schema.id.raw(view.pane_id), view_index);
    }
};

pub const Layout = struct {
    nodes: [max_nodes]Slot = [_]Slot{.{}} ** max_nodes,
    root: ?NodeIndex = null,
    focused_pane: schema.PaneId = .invalid,
    pane_count: u8 = 0,
    fullscreen: bool = false,
    pane_gaps: bool = true,
    revision: u64 = 1,

    pub fn count(layout: *const Layout) usize {
        return layout.pane_count;
    }

    pub fn focused(layout: *const Layout) ?schema.PaneId {
        return if (layout.focused_pane == .invalid) null else layout.focused_pane;
    }

    pub fn currentRevision(layout: *const Layout) u64 {
        return layout.revision;
    }

    pub fn isFullscreen(layout: *const Layout) bool {
        return layout.fullscreen;
    }

    /// Writes this split tree in the protocol's pre-order representation.
    ///
    /// ```zig
    /// var nodes: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined;
    /// const encoded = layout.clientLayoutNodes(&nodes);
    /// ```
    pub fn clientLayoutNodes(layout: *const Layout, output: *[schema.max_client_layout_nodes]schema.ClientLayoutNode) []const schema.ClientLayoutNode {
        const root = layout.root orelse return output[0..0];
        var stack: [max_nodes]NodeIndex = undefined;
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
    pub fn fromClientLayout(encoded: schema.ClientTabLayoutView) !Layout {
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
        if (layout.pane_gaps == enabled) return false;
        layout.pane_gaps = enabled;
        layout.changed();
        return true;
    }

    pub fn contains(layout: *const Layout, pane_id: schema.PaneId) bool {
        return layout.findLeaf(pane_id) != null;
    }

    /// One-based depth-first position used as the pane's disposable display
    /// index. Stable runtime ids never leak into the UI.
    pub fn displayIndex(layout: *const Layout, pane_id: schema.PaneId) ?u16 {
        const root = layout.root orelse return null;
        var stack: [max_nodes]NodeIndex = undefined;
        var stack_len: usize = 1;
        var index: u16 = 0;
        stack[0] = root;
        while (stack_len != 0) {
            stack_len -= 1;
            switch (layout.nodes[stack[stack_len]].node) {
                .empty => unreachable,
                .leaf => |candidate| {
                    index += 1;
                    if (candidate == pane_id) return index;
                },
                .split => |branch| {
                    stack[stack_len] = branch.second;
                    stack_len += 1;
                    stack[stack_len] = branch.first;
                    stack_len += 1;
                },
            }
        }
        return null;
    }

    pub fn addRoot(layout: *Layout, pane_id: schema.PaneId) !void {
        if (pane_id == .invalid) return error.InvalidPaneId;
        if (layout.root != null) return error.LayoutNotEmpty;
        layout.nodes[0] = .{ .node = .{ .leaf = pane_id } };
        layout.root = 0;
        layout.focused_pane = pane_id;
        layout.pane_count = 1;
        layout.fullscreen = false;
        layout.changed();
    }

    /// Rebuilds a disposable layout in the supplied display order and restores
    /// focus only after every pane has its canonical position.
    pub fn restoreDisplayOrder(
        layout: *Layout,
        pane_ids: []const schema.PaneId,
        focused_pane: schema.PaneId,
    ) !void {
        if (pane_ids.len == 0) return error.LayoutEmpty;
        var restored: Layout = .{
            .pane_gaps = layout.pane_gaps,
            .revision = layout.revision,
        };
        try restored.addRoot(pane_ids[0]);
        var previous = pane_ids[0];
        for (pane_ids[1..]) |pane_id| {
            try restored.split(previous, pane_id, .horizontal);
            previous = pane_id;
        }
        if (!restored.focusPane(focused_pane)) return error.PaneNotFound;
        layout.* = restored;
    }

    /// Restores an earlier client-owned split tree when it still describes
    /// exactly the panes reported by the runtime. Focus remains a separate
    /// navigation choice and the current pane-gap preference wins.
    pub fn restoreSaved(
        layout: *Layout,
        saved: Layout,
        pane_ids: []const schema.PaneId,
        focused_pane: schema.PaneId,
    ) bool {
        if (pane_ids.len == 0 or pane_ids.len != saved.count()) return false;
        for (pane_ids, 0..) |pane_id, index| {
            if (!saved.contains(pane_id)) return false;
            if (std.mem.findScalar(schema.PaneId, pane_ids[0..index], pane_id) != null)
                return false;
        }
        if (!saved.contains(focused_pane)) return false;

        var restored = saved;
        restored.pane_gaps = layout.pane_gaps;
        restored.revision = layout.revision;
        restored.focused_pane = focused_pane;
        restored.changed();
        layout.* = restored;
        return true;
    }

    pub fn splitFocused(layout: *Layout, pane_id: schema.PaneId, axis: Axis) !void {
        const focused_pane = layout.focused() orelse return error.LayoutEmpty;
        try layout.split(focused_pane, pane_id, axis);
    }

    pub fn split(
        layout: *Layout,
        existing_pane: schema.PaneId,
        new_pane: schema.PaneId,
        axis: Axis,
    ) !void {
        if (new_pane == .invalid) return error.InvalidPaneId;
        if (layout.contains(new_pane)) return error.DuplicatePane;
        if (layout.pane_count == max_panes) return error.PaneLimitReached;
        const target = layout.findLeaf(existing_pane) orelse return error.PaneNotFound;

        const first = layout.allocateNode() orelse return error.NodeLimitReached;
        errdefer layout.nodes[first] = .{};
        layout.nodes[first].node = .{ .leaf = .invalid };
        const second = layout.allocateNode() orelse return error.NodeLimitReached;
        const parent = layout.nodes[target].parent;
        layout.nodes[first] = .{ .parent = target, .node = .{ .leaf = existing_pane } };
        layout.nodes[second] = .{ .parent = target, .node = .{ .leaf = new_pane } };
        layout.nodes[target] = .{
            .parent = parent,
            .node = .{ .split = .{
                .axis = axis,
                .first = first,
                .second = second,
            } },
        };
        layout.focused_pane = new_pane;
        layout.pane_count += 1;
        layout.changed();
    }

    pub fn remove(layout: *Layout, pane_id: schema.PaneId) bool {
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
        if (layout.focused_pane == pane_id)
            layout.focused_pane = layout.firstLeaf(parent).?;
        if (layout.pane_count <= 1) layout.fullscreen = false;
        layout.changed();
        return true;
    }

    pub fn focusPane(layout: *Layout, pane_id: schema.PaneId) bool {
        if (!layout.contains(pane_id)) return false;
        if (layout.focused_pane == pane_id) return true;
        layout.focused_pane = pane_id;
        layout.changed();
        return true;
    }

    pub fn focusDirection(
        layout: *Layout,
        direction: Direction,
        area: ui.Rect,
    ) ?schema.PaneId {
        const current_id = layout.focused() orelse return null;
        var geometry: Snapshot = .{};
        layout.snapshotTiled(area, &geometry);
        const candidate = geometry.focusTarget(current_id, direction);
        if (candidate) |pane_id| {
            layout.focused_pane = pane_id;
            layout.changed();
        }
        return candidate;
    }

    /// Moves the nearest split edge in `direction` by five percent. If the
    /// requested edge is outside the tab, the nearest opposite edge moves in
    /// that direction instead. Ratios stay bounded and every leaf retains at
    /// least one content cell along the resized axis.
    pub fn resizeFocused(
        layout: *Layout,
        direction: Direction,
        area: ui.Rect,
    ) bool {
        const leaf = layout.findLeaf(layout.focused_pane) orelse return false;
        const target = layout.resizeSplit(leaf, direction) orelse return false;
        const branch = layout.nodes[target].node.split;
        const previous = branch.ratio;
        const adjusted = switch (direction) {
            .left, .up => previous -| resize_step,
            .right, .down => previous +| resize_step,
        };
        const candidate = std.math.clamp(
            adjusted,
            minimum_split_ratio,
            maximum_split_ratio,
        );
        if (candidate == previous) return false;
        const target_area = layout.nodeArea(target, area);
        if (!layout.ratioFits(branch, target_area, candidate)) return false;
        layout.nodes[target].node.split.ratio = candidate;
        layout.changed();
        return true;
    }

    pub fn toggleFullscreen(layout: *Layout) bool {
        if (layout.pane_count <= 1) return false;
        layout.fullscreen = !layout.fullscreen;
        layout.changed();
        return true;
    }

    pub fn canSplit(
        layout: *const Layout,
        pane_id: schema.PaneId,
        axis: Axis,
        area: ui.Rect,
    ) bool {
        var geometry: Snapshot = .{};
        layout.snapshot(area, &geometry);
        return geometry.prospectiveSplit(pane_id, axis, layout.pane_count) != null;
    }

    pub fn prospectiveSplit(
        layout: *const Layout,
        pane_id: schema.PaneId,
        axis: Axis,
        area: ui.Rect,
    ) ?ProspectiveSplit {
        var geometry: Snapshot = .{};
        layout.snapshot(area, &geometry);
        return geometry.prospectiveSplit(pane_id, axis, layout.pane_count);
    }

    pub fn snapshot(layout: *const Layout, area: ui.Rect, output: *Snapshot) void {
        if (!layout.fullscreen) return layout.snapshotTiled(area, output);
        output.reset(area, layout.revision, layout.pane_gaps);
        const pane_id = layout.focused() orelse return;
        output.append(.{
            .pane_id = pane_id,
            .outer = area,
            .content = area,
            .focused = true,
        });
    }

    fn snapshotTiled(layout: *const Layout, area: ui.Rect, output: *Snapshot) void {
        output.reset(area, layout.revision, layout.pane_gaps);
        const root = layout.root orelse return;
        const Pending = struct { node: NodeIndex, area: ui.Rect };
        var stack: [max_nodes]Pending = undefined;
        var stack_len: usize = 1;
        stack[0] = .{ .node = root, .area = area };
        while (stack_len != 0) {
            stack_len -= 1;
            const pending = stack[stack_len];
            switch (layout.nodes[pending.node].node) {
                .empty => unreachable,
                .leaf => |pane_id| output.append(.{
                    .pane_id = pane_id,
                    .outer = pending.area,
                    .content = if (layout.pane_count > 1)
                        borderedContent(pending.area)
                    else
                        pending.area,
                    .focused = pane_id == layout.focused_pane,
                }),
                .split => |branch| {
                    const first, const second = splitArea(
                        pending.area,
                        branch.axis,
                        branch.ratio,
                        layout.pane_gaps,
                    );
                    stack[stack_len] = .{ .node = branch.second, .area = second };
                    stack_len += 1;
                    stack[stack_len] = .{ .node = branch.first, .area = first };
                    stack_len += 1;
                },
            }
        }
    }

    pub fn views(
        layout: *const Layout,
        area: ui.Rect,
        output: *[max_panes]View,
    ) []View {
        var snapshot_output: Snapshot = .{};
        layout.snapshot(area, &snapshot_output);
        @memcpy(output[0..snapshot_output.len], snapshot_output.views());
        return output[0..snapshot_output.len];
    }

    fn resizeSplit(
        layout: *const Layout,
        leaf: NodeIndex,
        direction: Direction,
    ) ?NodeIndex {
        const target_axis: Axis = switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
        var fallback: ?NodeIndex = null;
        var child = leaf;
        while (layout.nodes[child].parent) |parent| {
            const branch = layout.nodes[parent].node.split;
            if (branch.axis == target_axis) {
                const child_is_first = branch.first == child;
                const requested_edge = switch (direction) {
                    .left, .up => !child_is_first,
                    .right, .down => child_is_first,
                };
                if (requested_edge) return parent;
                if (fallback == null) fallback = parent;
            }
            child = parent;
        }
        return fallback;
    }

    fn nodeArea(layout: *const Layout, target: NodeIndex, area: ui.Rect) ui.Rect {
        var path: [max_nodes]NodeIndex = undefined;
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
            const first, const second = splitArea(
                current_area,
                branch.axis,
                branch.ratio,
                layout.pane_gaps,
            );
            current_area = if (branch.first == child) first else second;
            current = child;
        }
        return current_area;
    }

    fn ratioFits(
        layout: *const Layout,
        branch: Split,
        area: ui.Rect,
        ratio: u16,
    ) bool {
        const first, const second = splitArea(area, branch.axis, ratio, layout.pane_gaps);
        const first_extent = extent(first, branch.axis);
        const second_extent = extent(second, branch.axis);
        return first_extent >= layout.minimumExtent(branch.first, branch.axis) and
            second_extent >= layout.minimumExtent(branch.second, branch.axis);
    }

    fn minimumExtent(layout: *const Layout, node_index: NodeIndex, axis: Axis) u16 {
        return switch (layout.nodes[node_index].node) {
            .empty => 0,
            .leaf => 3,
            .split => |branch| {
                const first = layout.minimumExtent(branch.first, axis);
                const second = layout.minimumExtent(branch.second, axis);
                if (branch.axis == axis)
                    return first +| @intFromBool(layout.pane_gaps) +| second;
                return @max(first, second);
            },
        };
    }

    fn allocateNode(layout: *Layout) ?NodeIndex {
        for (&layout.nodes, 0..) |*slot, index| {
            if (slot.node == .empty) return @intCast(index);
        }
        return null;
    }

    fn findLeaf(layout: *const Layout, pane_id: schema.PaneId) ?NodeIndex {
        for (layout.nodes, 0..) |slot, index| switch (slot.node) {
            .leaf => |candidate| if (candidate == pane_id) return @intCast(index),
            else => {},
        };
        return null;
    }

    fn firstLeaf(layout: *const Layout, start: NodeIndex) ?schema.PaneId {
        var current = start;
        while (true) switch (layout.nodes[current].node) {
            .empty => return null,
            .leaf => |pane_id| return pane_id,
            .split => |branch| current = branch.first,
        };
    }

    fn changed(layout: *Layout) void {
        layout.revision +%= 1;
        if (layout.revision == 0) layout.revision = 1;
    }
};

const ClientLayoutBuilder = struct {
    layout: Layout = .{},
    iterator: *schema.ClientLayoutNodeIterator,
    next_index: usize = 0,

    fn build(builder: *ClientLayoutBuilder, parent: ?NodeIndex) !NodeIndex {
        const encoded = try builder.iterator.next() orelse return error.InvalidClientLayoutTree;
        if (builder.next_index == max_nodes) {
            return error.NodeLimitReached;
        }

        const index: NodeIndex = @intCast(builder.next_index);
        builder.next_index += 1;
        switch (encoded) {
            .pane => |pane_id| {
                builder.layout.nodes[index] = .{ .parent = parent, .node = .{ .leaf = pane_id } };
                builder.layout.pane_count += 1;
            },
            .split => |split| {
                builder.layout.nodes[index] = .{ .parent = parent };
                const first = try builder.build(index);
                const second = try builder.build(index);
                builder.layout.nodes[index].node = .{ .split = .{
                    .axis = switch (split.axis) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .ratio = split.ratio,
                    .first = first,
                    .second = second,
                } };
            },
        }

        return index;
    }
};

fn splitArea(area: ui.Rect, axis: Axis, ratio: u16, pane_gaps: bool) [2]ui.Rect {
    std.debug.assert(ratio <= ratio_scale);
    return switch (axis) {
        .horizontal => horizontal: {
            const gutter: u16 = @intFromBool(pane_gaps and area.w >= 3);
            const usable = area.w - gutter;
            const first_width: u16 = @intCast(
                @as(u32, usable) * ratio / ratio_scale,
            );
            break :horizontal .{
                .{ .x = area.x, .y = area.y, .w = first_width, .h = area.h },
                .{
                    .x = area.x + first_width + gutter,
                    .y = area.y,
                    .w = usable - first_width,
                    .h = area.h,
                },
            };
        },
        .vertical => vertical: {
            const gutter: u16 = @intFromBool(pane_gaps and area.h >= 5);
            const usable = area.h - gutter;
            const first_height: u16 = @intCast(
                @as(u32, usable) * ratio / ratio_scale,
            );
            break :vertical .{
                .{ .x = area.x, .y = area.y, .w = area.w, .h = first_height },
                .{
                    .x = area.x,
                    .y = area.y + first_height + gutter,
                    .w = area.w,
                    .h = usable - first_height,
                },
            };
        },
    };
}

fn extent(area: ui.Rect, axis: Axis) u16 {
    return switch (axis) {
        .horizontal => area.w,
        .vertical => area.h,
    };
}

fn borderedContent(area: ui.Rect) ui.Rect {
    return area.inner(1);
}

fn center(origin: u16, length: u16) u32 {
    return @as(u32, origin) * 2 + length;
}

fn distance(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

test "splits produce non-overlapping bordered content rectangles" {
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(2), .horizontal);

    var storage: [max_panes]View = undefined;
    const visible = layout.views(.{ .w = 80, .h = 24 }, &storage);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqual(ui.Rect{ .w = 39, .h = 24 }, visible[0].outer);
    try std.testing.expectEqual(ui.Rect{ .x = 1, .y = 1, .w = 37, .h = 22 }, visible[0].content);
    try std.testing.expectEqual(ui.Rect{ .x = 40, .w = 40, .h = 24 }, visible[1].outer);
    try std.testing.expectEqual(@as(u16, 1), visible[1].outer.x - visible[0].outer.w);
    try std.testing.expect(visible[1].focused);
}

test "disabled pane gaps remove the empty cell between borders" {
    var layout: Layout = .{};
    try std.testing.expect(layout.setPaneGaps(false));
    try std.testing.expect(!layout.setPaneGaps(false));
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(2), .horizontal);

    var storage: [max_panes]View = undefined;
    const visible = layout.views(.{ .w = 80, .h = 24 }, &storage);
    try std.testing.expectEqual(ui.Rect{ .w = 40, .h = 24 }, visible[0].outer);
    try std.testing.expectEqual(ui.Rect{ .x = 40, .w = 40, .h = 24 }, visible[1].outer);
    try std.testing.expectEqual(visible[0].outer.w, visible[1].outer.x);
}

test "disabled pane gaps permit the smallest pair of bordered panes" {
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    const area: ui.Rect = .{ .w = 6, .h = 3 };
    try std.testing.expect(!layout.canSplit(@enumFromInt(1), .horizontal, area));
    _ = layout.setPaneGaps(false);
    try std.testing.expect(layout.canSplit(@enumFromInt(1), .horizontal, area));
}

test "directional focus follows pane geometry" {
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(2), .horizontal);
    try layout.splitFocused(@enumFromInt(3), .vertical);

    const area: ui.Rect = .{ .w = 80, .h = 24 };
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(2)), layout.focusDirection(.up, area).?);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), layout.focusDirection(.left, area).?);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(2)), layout.focusDirection(.right, area).?);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(3)), layout.focusDirection(.down, area).?);
}

test "directional resize grows and shrinks horizontal and vertical panes" {
    const area: ui.Rect = .{ .w = 101, .h = 41 };

    var horizontal: Layout = .{};
    try horizontal.addRoot(@enumFromInt(1));
    try horizontal.splitFocused(@enumFromInt(2), .horizontal);
    try std.testing.expect(horizontal.focusPane(@enumFromInt(1)));
    var geometry: Snapshot = .{};
    horizontal.snapshot(area, &geometry);
    const horizontal_before = geometry.find(@enumFromInt(1)).?.outer.w;
    try std.testing.expect(horizontal.resizeFocused(.right, area));
    horizontal.snapshot(area, &geometry);
    try std.testing.expect(geometry.find(@enumFromInt(1)).?.outer.w > horizontal_before);
    try std.testing.expect(horizontal.resizeFocused(.left, area));
    horizontal.snapshot(area, &geometry);
    try std.testing.expectEqual(horizontal_before, geometry.find(@enumFromInt(1)).?.outer.w);

    var vertical: Layout = .{};
    try vertical.addRoot(@enumFromInt(1));
    try vertical.splitFocused(@enumFromInt(2), .vertical);
    try std.testing.expect(vertical.focusPane(@enumFromInt(1)));
    vertical.snapshot(area, &geometry);
    const vertical_before = geometry.find(@enumFromInt(1)).?.outer.h;
    try std.testing.expect(vertical.resizeFocused(.down, area));
    vertical.snapshot(area, &geometry);
    try std.testing.expect(geometry.find(@enumFromInt(1)).?.outer.h > vertical_before);
    try std.testing.expect(vertical.resizeFocused(.up, area));
    vertical.snapshot(area, &geometry);
    try std.testing.expectEqual(vertical_before, geometry.find(@enumFromInt(1)).?.outer.h);
}

test "resize selects the nearest matching ancestor and preserves usable pane content" {
    const area: ui.Rect = .{ .w = 80, .h = 24 };
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(2), .horizontal);
    try layout.splitFocused(@enumFromInt(3), .vertical);

    var geometry: Snapshot = .{};
    layout.snapshot(area, &geometry);
    const left_before = geometry.find(@enumFromInt(1)).?.outer.w;
    const focused_before = geometry.find(@enumFromInt(3)).?.outer.h;
    try std.testing.expect(layout.resizeFocused(.left, area));
    layout.snapshot(area, &geometry);
    try std.testing.expect(geometry.find(@enumFromInt(1)).?.outer.w < left_before);
    try std.testing.expectEqual(focused_before, geometry.find(@enumFromInt(3)).?.outer.h);

    var constrained: Layout = .{};
    try constrained.addRoot(@enumFromInt(4));
    try constrained.splitFocused(@enumFromInt(5), .horizontal);
    try std.testing.expect(constrained.focusPane(@enumFromInt(4)));
    while (constrained.resizeFocused(.right, .{ .w = 7, .h = 3 })) {}
    constrained.snapshot(.{ .w = 7, .h = 3 }, &geometry);
    for (geometry.views()) |view| {
        try std.testing.expect(view.content.w >= 1);
        try std.testing.expect(view.content.h >= 1);
    }
}

test "fullscreen toggles one pane without destroying the tiled layout" {
    const area: ui.Rect = .{ .w = 101, .h = 41 };
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try std.testing.expect(!layout.toggleFullscreen());
    try layout.splitFocused(@enumFromInt(2), .horizontal);
    try std.testing.expect(layout.focusPane(@enumFromInt(1)));
    try std.testing.expect(layout.resizeFocused(.right, area));

    var geometry: Snapshot = .{};
    layout.snapshot(area, &geometry);
    const first_width = geometry.find(@enumFromInt(1)).?.outer.w;
    const second_width = geometry.find(@enumFromInt(2)).?.outer.w;

    try std.testing.expect(layout.toggleFullscreen());
    try std.testing.expect(layout.isFullscreen());
    layout.snapshot(area, &geometry);
    try std.testing.expectEqual(@as(usize, 1), geometry.views().len);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), geometry.views()[0].pane_id);
    try std.testing.expectEqual(area, geometry.views()[0].outer);
    try std.testing.expectEqual(area, geometry.views()[0].content);

    try std.testing.expectEqual(
        @as(schema.PaneId, @enumFromInt(2)),
        layout.focusDirection(.right, area).?,
    );
    layout.snapshot(area, &geometry);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(2)), geometry.views()[0].pane_id);

    try std.testing.expect(layout.toggleFullscreen());
    try std.testing.expect(!layout.isFullscreen());
    layout.snapshot(area, &geometry);
    try std.testing.expectEqual(@as(usize, 2), geometry.views().len);
    try std.testing.expectEqual(first_width, geometry.find(@enumFromInt(1)).?.outer.w);
    try std.testing.expectEqual(second_width, geometry.find(@enumFromInt(2)).?.outer.w);
}

test "removing a fullscreen pane clears fullscreen when one pane remains" {
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(2), .horizontal);
    try std.testing.expect(layout.toggleFullscreen());
    try std.testing.expect(layout.remove(@enumFromInt(2)));
    try std.testing.expect(!layout.isFullscreen());
}

test "removing a leaf compacts its parent and preserves the sibling" {
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(2), .horizontal);
    try layout.splitFocused(@enumFromInt(3), .vertical);

    try std.testing.expect(layout.remove(@enumFromInt(2)));
    try std.testing.expectEqual(@as(usize, 2), layout.count());
    try std.testing.expect(!layout.contains(@enumFromInt(2)));
    try std.testing.expect(layout.contains(@enumFromInt(3)));
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(3)), layout.focused().?);
}

test "tiny panes reject splits that would create a zero-row PTY" {
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try std.testing.expect(!layout.canSplit(@enumFromInt(1), .vertical, .{ .w = 8, .h = 3 }));
    try std.testing.expect(layout.canSplit(@enumFromInt(1), .horizontal, .{ .w = 8, .h = 3 }));
}

test "snapshot indexes colliding pane ids and records its source revision" {
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(129), .horizontal);

    var geometry: Snapshot = .{};
    layout.snapshot(.{ .w = 80, .h = 24 }, &geometry);

    try std.testing.expectEqual(layout.currentRevision(), geometry.revision);
    try std.testing.expectEqual(@as(u16, 39), geometry.find(@enumFromInt(1)).?.outer.w);
    try std.testing.expectEqual(@as(u16, 40), geometry.find(@enumFromInt(129)).?.outer.w);
    try std.testing.expectEqual(@as(?View, null), geometry.find(@enumFromInt(257)));
}

test "focus changes advance the layout revision" {
    var layout: Layout = .{};
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(2), .horizontal);
    const before = layout.currentRevision();

    try std.testing.expect(layout.focusPane(@enumFromInt(1)));
    try std.testing.expect(layout.currentRevision() != before);
    const focused_revision = layout.currentRevision();
    try std.testing.expect(layout.focusPane(@enumFromInt(1)));
    try std.testing.expectEqual(focused_revision, layout.currentRevision());
}

test "client layout encoding restores splits ratios focus and fullscreen" {
    var original: Layout = .{};
    try original.addRoot(@enumFromInt(1));
    try original.splitFocused(@enumFromInt(2), .horizontal);
    try original.splitFocused(@enumFromInt(3), .vertical);
    try std.testing.expect(original.focusPane(@enumFromInt(1)));
    try std.testing.expect(original.resizeFocused(.right, .{ .w = 100, .h = 40 }));
    try std.testing.expect(original.toggleFullscreen());

    var node_storage: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined;
    const nodes = original.clientLayoutNodes(&node_storage);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(4) },
        .tab_id = @enumFromInt(5),
    };
    var wire: [schema.max_client_layout_wire_bytes]u8 = undefined;
    const payload = try schema.encodeClientLayoutSnapshot(&wire, .{
        .restored = true,
        .sidebar_width = 62,
        .active_tab = location,
        .tabs = &.{.{
            .location = location,
            .focused_pane = original.focused().?,
            .fullscreen = original.isFullscreen(),
            .workspace_active = true,
            .nodes = nodes,
        }},
    });
    var tabs = (try schema.decodeServer(payload)).client_layout_snapshot.tabs();
    const restored = try Layout.fromClientLayout((try tabs.next()).?);

    try std.testing.expectEqual(original.count(), restored.count());
    try std.testing.expectEqual(original.focused().?, restored.focused().?);
    try std.testing.expect(restored.isFullscreen());
    var restored_storage: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined;
    const restored_nodes = restored.clientLayoutNodes(&restored_storage);
    try std.testing.expectEqual(nodes.len, restored_nodes.len);
    for (nodes, restored_nodes) |expected, actual| {
        try std.testing.expectEqualDeep(expected, actual);
    }
}
