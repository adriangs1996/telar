const ClientLayoutBuilder = @This();
const Layout = @import("Layout.zig");
const source_namespace = @import("layout_support.zig");
layout: Layout = .{},
iterator: *source_namespace.schema.ClientLayoutNodeIterator,
next_index: usize = 0,

pub fn build(builder: *ClientLayoutBuilder, parent: ?source_namespace.NodeIndex) !source_namespace.NodeIndex {
    const encoded = try builder.iterator.next() orelse return error.InvalidClientLayoutTree;
    if (builder.next_index == source_namespace.max_nodes) {
        return error.NodeLimitReached;
    }

    const index: source_namespace.NodeIndex = @intCast(builder.next_index);
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
