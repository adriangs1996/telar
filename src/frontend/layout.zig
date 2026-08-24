//! Disposable pane layout owned by the client.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;
const ui = core.ui;

pub const max_panes = schema.max_panes_per_tab;
const max_nodes = max_panes * 2 - 1;
const NodeIndex = u8;
const index_capacity = max_panes * 2;

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

const ViewIndexEntry = struct {
    pane_id: schema.PaneId = .invalid,
    view_index: u8 = 0,
};

/// Immutable geometry consumed by every subsystem during a frame. Building it
/// is O(panes); pane lookup is bounded open addressing with no allocations.
pub const Snapshot = struct {
    area: ui.Rect = .{},
    revision: u64 = 0,
    storage: [max_panes]View = undefined,
    len: u8 = 0,
    index: [index_capacity]ViewIndexEntry = [_]ViewIndexEntry{.{}} ** index_capacity,

    pub fn views(snapshot: *const Snapshot) []const View {
        return snapshot.storage[0..snapshot.len];
    }

    pub fn find(snapshot: *const Snapshot, pane_id: schema.PaneId) ?View {
        if (pane_id == .invalid) return null;
        var slot = hashPane(pane_id);
        var probes: usize = 0;
        while (probes < index_capacity) : (probes += 1) {
            const entry = snapshot.index[slot];
            if (entry.pane_id == .invalid) return null;
            if (entry.pane_id == pane_id) return snapshot.storage[entry.view_index];
            slot = (slot + 1) & (index_capacity - 1);
        }
        return null;
    }

    pub fn prospectiveSplit(
        snapshot: *const Snapshot,
        pane_id: schema.PaneId,
        axis: Axis,
        pane_count: usize,
    ) ?ProspectiveSplit {
        if (pane_count == max_panes) return null;
        const view = snapshot.find(pane_id) orelse return null;
        const enough_space = switch (axis) {
            // Two bordered PTYs plus their gutter.
            .horizontal => view.outer.w >= 7 and view.outer.h >= 3,
            .vertical => view.outer.w >= 3 and view.outer.h >= 7,
        };
        if (!enough_space) return null;
        const first, const second = splitArea(view.outer, axis);
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

    fn reset(snapshot: *Snapshot, area: ui.Rect, revision: u64) void {
        snapshot.area = area;
        snapshot.revision = revision;
        snapshot.len = 0;
        @memset(&snapshot.index, .{});
    }

    fn append(snapshot: *Snapshot, view: View) void {
        const view_index = snapshot.len;
        snapshot.storage[view_index] = view;
        snapshot.len += 1;
        var slot = hashPane(view.pane_id);
        while (snapshot.index[slot].pane_id != .invalid)
            slot = (slot + 1) & (index_capacity - 1);
        snapshot.index[slot] = .{ .pane_id = view.pane_id, .view_index = view_index };
    }
};

pub const Layout = struct {
    nodes: [max_nodes]Slot = [_]Slot{.{}} ** max_nodes,
    root: ?NodeIndex = null,
    focused_pane: schema.PaneId = .invalid,
    pane_count: u8 = 0,
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

    pub fn contains(layout: *const Layout, pane_id: schema.PaneId) bool {
        return layout.findLeaf(pane_id) != null;
    }

    pub fn addRoot(layout: *Layout, pane_id: schema.PaneId) !void {
        if (pane_id == .invalid) return error.InvalidPaneId;
        if (layout.root != null) return error.LayoutNotEmpty;
        layout.nodes[0] = .{ .node = .{ .leaf = pane_id } };
        layout.root = 0;
        layout.focused_pane = pane_id;
        layout.pane_count = 1;
        layout.changed();
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
            .node = .{ .split = .{ .axis = axis, .first = first, .second = second } },
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
        layout.snapshot(area, &geometry);
        const candidate = geometry.focusTarget(current_id, direction);
        if (candidate) |pane_id| {
            layout.focused_pane = pane_id;
            layout.changed();
        }
        return candidate;
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
        output.reset(area, layout.revision);
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
                    const first, const second = splitArea(pending.area, branch.axis);
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

fn hashPane(pane_id: schema.PaneId) usize {
    const mixed = schema.id.raw(pane_id) *% 0x9e3779b97f4a7c15;
    return @as(usize, @truncate(mixed)) & (index_capacity - 1);
}

fn splitArea(area: ui.Rect, axis: Axis) [2]ui.Rect {
    return switch (axis) {
        .horizontal => horizontal: {
            const gutter: u16 = @intFromBool(area.w >= 3);
            const usable = area.w - gutter;
            const first_width = usable / 2;
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
            const gutter: u16 = @intFromBool(area.h >= 5);
            const usable = area.h - gutter;
            const first_height = usable / 2;
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
