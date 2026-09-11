const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const LayoutType = @import("WorkspaceLayout.zig");
const max_client_layout_nodes_module = @import("telar-core").max_client_layout_nodes;
const ClientLayoutNodeType = @import("telar-core").ClientLayoutNode;
const LayoutSnapshot = @import("LayoutSnapshot.zig");
const std = @import("std");
const MetricsType = @import("Metrics.zig");

const first: PaneIdType = @enumFromInt(1);
const second: PaneIdType = @enumFromInt(2);
const area: RectType = .{ .w = 80, .h = 24 };

test "presentation measurements change geometry without changing the split tree" {
    var tree: LayoutType = .{};
    try tree.addRoot(first);
    try tree.splitFocused(second, .horizontal);
    var before_nodes: [max_client_layout_nodes_module]ClientLayoutNodeType = undefined;
    const before = tree.clientLayoutNodes(&before_nodes);
    var terminal: LayoutSnapshot = .{};
    tree.snapshot(area, &terminal);

    try std.testing.expect(tree.setMetrics(.{ .border = 0, .gap = 0 }));
    var native: LayoutSnapshot = .{};
    tree.snapshot(area, &native);
    var after_nodes: [max_client_layout_nodes_module]ClientLayoutNodeType = undefined;
    try std.testing.expectEqualDeep(before, tree.clientLayoutNodes(&after_nodes));
    try std.testing.expectEqual(area.w / 2, native.find(first).?.content.w);
    try std.testing.expectEqualDeep(native.find(first).?.outer, native.find(first).?.content);
    try std.testing.expect(terminal.find(first).?.content.w < native.find(first).?.content.w);
    try std.testing.expect(terminal.revision != native.revision);
    try std.testing.expectEqual(terminal.focusTarget(first, .right), native.focusTarget(first, .right));
    try std.testing.expect(!tree.setMetrics(.{ .border = 0, .gap = 0 }));
}

test "restoring layout keeps current presentation measurements" {
    var tree: LayoutType = .{};
    try tree.addRoot(first);
    try tree.splitFocused(second, .horizontal);
    const saved = tree;
    _ = tree.setMetrics(.{ .border = 0, .gap = 0 });
    try std.testing.expect(tree.restoreSaved(saved, .{ .ids = &.{ first, second }, .focused = second }));
    try std.testing.expectEqualDeep(MetricsType{ .border = 0, .gap = 0 }, tree.metrics);
    try tree.restoreDisplayOrder(&.{ second, first }, first);
    try std.testing.expectEqualDeep(MetricsType{ .border = 0, .gap = 0 }, tree.metrics);
}
