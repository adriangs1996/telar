const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const data = @import("model");
const std = @import("std");

const first: core.PaneId = @enumFromInt(1);
const second: core.PaneId = @enumFromInt(2);
const area: cellgrid.Rect = .{ .w = 80, .h = 24 };

test "presentation measurements change geometry without changing the split tree" {
    var tree: data.WorkspaceLayout = .{};
    try tree.addRoot(first);
    try tree.splitFocused(second, .horizontal);
    var before_nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    const before = tree.clientLayoutNodes(&before_nodes);
    var terminal: data.LayoutSnapshot = .{};
    tree.snapshot(area, &terminal);

    try std.testing.expect(tree.setMetrics(.{ .border = 0, .gap = 0 }));
    var native: data.LayoutSnapshot = .{};
    tree.snapshot(area, &native);
    var after_nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    try std.testing.expectEqualDeep(before, tree.clientLayoutNodes(&after_nodes));
    try std.testing.expectEqual(area.w / 2, native.find(first).?.content.w);
    try std.testing.expectEqualDeep(native.find(first).?.outer, native.find(first).?.content);
    try std.testing.expect(terminal.find(first).?.content.w < native.find(first).?.content.w);
    try std.testing.expect(terminal.revision != native.revision);
    try std.testing.expectEqual(terminal.focusTarget(first, .right), native.focusTarget(first, .right));
    try std.testing.expect(!tree.setMetrics(.{ .border = 0, .gap = 0 }));
}

test "restoring layout keeps current presentation measurements" {
    var tree: data.WorkspaceLayout = .{};
    try tree.addRoot(first);
    try tree.splitFocused(second, .horizontal);
    const saved = tree;
    _ = tree.setMetrics(.{ .border = 0, .gap = 0 });
    try std.testing.expect(tree.restoreSaved(saved, .{ .ids = &.{ first, second }, .focused = second }));
    try std.testing.expectEqualDeep(data.Metrics{ .border = 0, .gap = 0 }, tree.metrics);
    try tree.restoreDisplayOrder(&.{ second, first }, first);
    try std.testing.expectEqualDeep(data.Metrics{ .border = 0, .gap = 0 }, tree.metrics);
}
