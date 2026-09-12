const Layout = @import("WorkspaceLayout.zig");
const ClientLayoutNodeIteratorType = @import("telar-core").ClientLayoutNodeIterator;
const layout_support = @import("layout_support.zig");
const ClientLayoutBuilder = @This();

layout: Layout = .{},
iterator: *ClientLayoutNodeIteratorType,
next_index: usize = 0,

pub fn build(builder: *ClientLayoutBuilder, parent: ?layout_support.NodeIndex) !layout_support.NodeIndex {
    const encoded = try builder.iterator.next() orelse return error.InvalidClientLayoutTree;
    if (builder.next_index == layout_support.max_nodes) {
        return error.NodeLimitReached;
    }

    const index: layout_support.NodeIndex = @intCast(builder.next_index);
    builder.next_index += 1;
    switch (encoded) {
        .pane => |pane| {
            builder.layout.nodes[index] = .{ .parent = parent, .node = .{ .leaf = pane.id }, .surface = pane.surface };
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
