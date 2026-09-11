//! Disposable pane layout owned by the client.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;
pub const ui = core.ui;

pub const Metrics = @import("metrics_support.zig").Metrics;
pub const max_panes = schema.max_panes_per_tab;
pub const max_nodes = max_panes * 2 - 1;
pub const NodeIndex = u8;
const index_capacity = max_panes * 2;
pub const ViewIndex = core.fixed_index.SlotIndex(index_capacity);
const ratio_scale: u16 = schema.client_layout_ratio_scale;
pub const default_split_ratio: u16 = ratio_scale / 2;
pub const minimum_split_ratio: u16 = schema.min_client_layout_ratio;
pub const maximum_split_ratio: u16 = schema.max_client_layout_ratio;
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

const Split = @import("Split.zig");

pub const Node = union(enum) {
    empty,
    leaf: schema.PaneId,
    split: Split,
};

const Slot = @import("Slot.zig");

pub const View = @import("View.zig");

pub const PaneBottomReservation = @import("PaneBottomReservation.zig");

pub const ProspectiveSplit = @import("ProspectiveSplit.zig");

pub const SplitTarget = @import("SplitTarget.zig");

pub const SplitRequest = @import("SplitRequest.zig");

pub const PaneSet = @import("PaneSet.zig");

const SnapshotReset = @import("SnapshotReset.zig");

const RatioCandidate = @import("RatioCandidate.zig");

const SplitGeometry = @import("SplitGeometry.zig");

pub const Snapshot = @import("LayoutSnapshot.zig");

pub const Layout = @import("Layout.zig");

const ClientLayoutBuilder = @import("ClientLayoutBuilder.zig");

pub fn splitArea(geometry: SplitGeometry) [2]ui.Rect {
    std.debug.assert(geometry.ratio <= ratio_scale);

    return switch (geometry.axis) {
        .horizontal => horizontal: {
            const gutter: u16 = if (geometry.area.w >= geometry.gap + 2) geometry.gap else 0;
            const usable = geometry.area.w - gutter;
            const first_width: u16 = @intCast(
                @as(u32, usable) * geometry.ratio / ratio_scale,
            );
            break :horizontal .{
                .{ .x = geometry.area.x, .y = geometry.area.y, .w = first_width, .h = geometry.area.h },
                .{
                    .x = geometry.area.x + first_width + gutter,
                    .y = geometry.area.y,
                    .w = usable - first_width,
                    .h = geometry.area.h,
                },
            };
        },
        .vertical => vertical: {
            const gutter: u16 = if (geometry.area.h >= geometry.gap + 4) geometry.gap else 0;
            const usable = geometry.area.h - gutter;
            const first_height: u16 = @intCast(
                @as(u32, usable) * geometry.ratio / ratio_scale,
            );
            break :vertical .{
                .{ .x = geometry.area.x, .y = geometry.area.y, .w = geometry.area.w, .h = first_height },
                .{
                    .x = geometry.area.x,
                    .y = geometry.area.y + first_height + gutter,
                    .w = geometry.area.w,
                    .h = usable - first_height,
                },
            };
        },
    };
}

/// The ratio that gives the first of `remaining` panes an equal share of a
/// region, bounded by the ratios a client layout may carry.
pub fn equalShareRatio(remaining: usize) u16 {
    const share: u16 = @intCast(ratio_scale / remaining);
    return std.math.clamp(share, minimum_split_ratio, maximum_split_ratio);
}

pub fn extent(area: ui.Rect, axis: Axis) u16 {
    return switch (axis) {
        .horizontal => area.w,
        .vertical => area.h,
    };
}

fn borderedContent(area: ui.Rect) ui.Rect {
    return area.inner(1);
}

pub fn center(origin: u16, length: u16) u32 {
    return @as(u32, origin) * 2 + length;
}

pub fn distance(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

test "display order shares the width equally and clamps a crowded tab" {
    var layout: Layout = .{ .pane_gaps = false };
    const panes = [_]schema.PaneId{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3), @enumFromInt(4), @enumFromInt(5) };
    try layout.restoreDisplayOrder(&panes, @enumFromInt(3));

    var geometry: Snapshot = .{};
    layout.snapshot(.{ .w = 100, .h = 10 }, &geometry);
    var total: u16 = 0;
    for (panes) |pane_id| {
        const width = geometry.find(pane_id).?.outer.w;
        try std.testing.expect(width >= 19 and width <= 21);
        total += width;
    }
    try std.testing.expectEqual(@as(u16, 100), total);
    try std.testing.expectEqual(@as(?schema.PaneId, @enumFromInt(3)), layout.focused());

    var crowded: [12]schema.PaneId = undefined;
    for (&crowded, 1..) |*pane_id, raw| {
        pane_id.* = @enumFromInt(raw);
    }
    try layout.restoreDisplayOrder(&crowded, crowded[0]);
    layout.snapshot(.{ .w = 100, .h = 10 }, &geometry);
    try std.testing.expectEqual(@as(u16, 10), geometry.find(crowded[0]).?.outer.w);
    try std.testing.expectEqual(@as(usize, 12), geometry.views().len);
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
    try std.testing.expect(!layout.canSplit(.{ .pane_id = @enumFromInt(1), .axis = .horizontal }, area));
    _ = layout.setPaneGaps(false);
    try std.testing.expect(layout.canSplit(.{ .pane_id = @enumFromInt(1), .axis = .horizontal }, area));
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

test "bottom reservation shortens only its target pane" {
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    var layout: Layout = .{};
    try layout.addRoot(first);
    try layout.splitFocused(second, .horizontal);

    var geometry: Snapshot = .{};
    layout.snapshot(.{ .w = 80, .h = 24 }, &geometry);
    const first_before = geometry.find(first).?;
    const second_before = geometry.find(second).?;
    const shelf = geometry.reserveBelowPane(.{
        .pane_id = second,
        .preferred_height = 6,
        .minimum_height = 3,
        .minimum_pane_height = 3,
    });
    const first_after = geometry.find(first).?;
    const second_after = geometry.find(second).?;

    try std.testing.expectEqualDeep(first_before, first_after);
    try std.testing.expectEqual(second_before.outer.x, shelf.x);
    try std.testing.expectEqual(second_before.outer.w, shelf.w);
    try std.testing.expectEqual(second_after.outer.y + second_after.outer.h, shelf.y);
    try std.testing.expectEqual(second_before.outer.h, second_after.outer.h + shelf.h);
    try std.testing.expectEqual(@as(u16, 6), shelf.h);
}

test "bottom reservation preserves a minimum pane height" {
    const pane_id: schema.PaneId = @enumFromInt(1);
    var layout: Layout = .{};
    try layout.addRoot(pane_id);

    var geometry: Snapshot = .{};
    layout.snapshot(.{ .w = 20, .h = 5 }, &geometry);
    const before = geometry.find(pane_id).?;
    const shelf = geometry.reserveBelowPane(.{
        .pane_id = pane_id,
        .preferred_height = 6,
        .minimum_height = 3,
        .minimum_pane_height = 3,
    });

    try std.testing.expect(shelf.isEmpty());
    try std.testing.expectEqualDeep(before, geometry.find(pane_id).?);
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
    try std.testing.expect(!layout.toggleFullscreen());
    try layout.addRoot(@enumFromInt(1));
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
    try std.testing.expectEqual(borderedContent(area), geometry.views()[0].content);
    try std.testing.expectEqual(@as(u16, 1), geometry.views()[0].display_index);

    try std.testing.expectEqual(
        @as(schema.PaneId, @enumFromInt(2)),
        layout.focusDirection(.right, area).?,
    );
    layout.snapshot(area, &geometry);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(2)), geometry.views()[0].pane_id);
    try std.testing.expectEqual(@as(u16, 2), geometry.views()[0].display_index);

    try std.testing.expect(layout.toggleFullscreen());
    try std.testing.expect(!layout.isFullscreen());
    layout.snapshot(area, &geometry);
    try std.testing.expectEqual(@as(usize, 2), geometry.views().len);
    try std.testing.expectEqual(first_width, geometry.find(@enumFromInt(1)).?.outer.w);
    try std.testing.expectEqual(second_width, geometry.find(@enumFromInt(2)).?.outer.w);
}

test "fullscreen navigation follows display order and restores spatial geometry" {
    const area: ui.Rect = .{ .w = 101, .h = 41 };
    const first: schema.PaneId = @enumFromInt(10);
    const second: schema.PaneId = @enumFromInt(90);
    const third: schema.PaneId = @enumFromInt(40);
    var layout: Layout = .{};
    try layout.addRoot(first);
    try layout.splitFocused(second, .horizontal);
    try std.testing.expect(layout.focusPane(first));
    try layout.splitFocused(third, .vertical);
    try std.testing.expect(layout.resizeFocused(.right, area));
    try std.testing.expect(layout.resizeFocused(.up, area));
    try std.testing.expect(layout.focusPane(first));

    var storage: [max_panes]schema.PaneId = undefined;
    try std.testing.expectEqualSlices(schema.PaneId, &.{ first, third, second }, layout.orderedPanes(&storage));
    var before: Snapshot = .{};
    layout.snapshot(area, &before);
    var nodes: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined;
    const original = layout.clientLayoutNodes(&nodes);
    try std.testing.expect(layout.toggleFullscreen());

    const start_revision = layout.currentRevision();
    try std.testing.expect(layout.focusDirection(.left, area) == null);
    try std.testing.expect(layout.focusDirection(.up, area) == null);
    try std.testing.expect(layout.focusDirection(.down, area) == null);
    try std.testing.expectEqual(start_revision, layout.currentRevision());
    try std.testing.expectEqual(third, layout.focusDirection(.right, area).?);
    try std.testing.expectEqual(second, layout.focusDirection(.right, area).?);
    const end_revision = layout.currentRevision();
    try std.testing.expect(layout.focusDirection(.right, area) == null);
    try std.testing.expectEqual(end_revision, layout.currentRevision());
    try std.testing.expectEqual(third, layout.focusDirection(.left, area).?);

    try std.testing.expect(layout.toggleFullscreen());
    try std.testing.expectEqual(third, layout.focused().?);
    var restored_nodes: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined;
    try std.testing.expectEqualDeep(original, layout.clientLayoutNodes(&restored_nodes));
    var after: Snapshot = .{};
    layout.snapshot(area, &after);
    for (before.views(), after.views()) |previous, current| {
        try std.testing.expectEqual(previous.pane_id, current.pane_id);
        try std.testing.expectEqual(previous.outer, current.outer);
        try std.testing.expectEqual(previous.content, current.content);
    }

    try std.testing.expectEqual(first, layout.focusDirection(.up, area).?);
    try std.testing.expectEqual(third, layout.focusDirection(.down, area).?);
    try std.testing.expectEqual(second, layout.focusDirection(.right, area).?);
}

test "fullscreen pane order tracks splits and removals" {
    var layout: Layout = .{};
    var storage: [max_panes]schema.PaneId = undefined;
    try std.testing.expectEqual(@as(usize, 0), layout.orderedPanes(&storage).len);
    try layout.addRoot(@enumFromInt(1));
    try layout.splitFocused(@enumFromInt(2), .vertical);
    try std.testing.expect(layout.toggleFullscreen());
    try layout.splitFocused(@enumFromInt(3), .horizontal);
    try std.testing.expect(layout.isFullscreen());
    try std.testing.expect(layout.remove(@enumFromInt(2)));
    try std.testing.expectEqualSlices(schema.PaneId, &.{ @enumFromInt(1), @enumFromInt(3) }, layout.orderedPanes(&storage));
    try std.testing.expectEqual(@as(u16, 2), layout.displayIndex(@enumFromInt(3)).?);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), layout.focusDirection(.left, .{}).?);
}

test "fullscreen survives single-pane splits and removals until the tab is empty" {
    const area: ui.Rect = .{ .w = 101, .h = 41 };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    var layout: Layout = .{};
    try layout.addRoot(first);
    try std.testing.expect(!layout.hasBorders());
    try std.testing.expect(layout.toggleFullscreen());
    try std.testing.expect(layout.hasBorders());
    var geometry: Snapshot = .{};
    layout.snapshot(area, &geometry);
    try std.testing.expectEqual(borderedContent(area), geometry.find(first).?.content);

    const revision = layout.currentRevision();
    for ([_]Direction{ .left, .right, .up, .down }) |direction| {
        try std.testing.expect(layout.focusDirection(direction, area) == null);
    }

    try std.testing.expectEqual(revision, layout.currentRevision());
    try layout.splitFocused(second, .horizontal);
    try std.testing.expect(layout.isFullscreen());
    try std.testing.expectEqual(second, layout.focused().?);
    layout.snapshot(area, &geometry);
    try std.testing.expectEqual(@as(usize, 1), geometry.views().len);
    try std.testing.expectEqual(borderedContent(area), geometry.find(second).?.content);
    try std.testing.expectEqual(first, layout.focusDirection(.left, area).?);
    try std.testing.expectEqual(second, layout.focusDirection(.right, area).?);
    try std.testing.expect(layout.remove(second));
    try std.testing.expect(layout.isFullscreen());
    try std.testing.expectEqual(first, layout.focused().?);

    try std.testing.expect(layout.toggleFullscreen());
    layout.snapshot(area, &geometry);
    try std.testing.expectEqual(area, geometry.find(first).?.content);
    try std.testing.expect(!layout.hasBorders());
    try std.testing.expect(layout.toggleFullscreen());
    try std.testing.expect(layout.remove(first));
    try std.testing.expect(!layout.isFullscreen());
    try std.testing.expect(!layout.hasBorders());
    try std.testing.expect(!layout.toggleFullscreen());
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
    try std.testing.expect(!layout.canSplit(.{ .pane_id = @enumFromInt(1), .axis = .vertical }, .{ .w = 8, .h = 3 }));
    try std.testing.expect(layout.canSplit(.{ .pane_id = @enumFromInt(1), .axis = .horizontal }, .{ .w = 8, .h = 3 }));
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

test "client layout encoding restores single and split pane fullscreen" {
    for ([_]bool{ false, true }) |split| {
        var original: Layout = .{};
        try original.addRoot(@enumFromInt(1));
        if (split) {
            try original.splitFocused(@enumFromInt(2), .horizontal);
            try original.splitFocused(@enumFromInt(3), .vertical);
            try std.testing.expect(original.focusPane(@enumFromInt(1)));
            try std.testing.expect(original.resizeFocused(.right, .{ .w = 100, .h = 40 }));
        }

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
}
