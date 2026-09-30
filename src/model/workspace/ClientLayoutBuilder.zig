const core = @import("telar-core");
const Layout = @import("WorkspaceLayout.zig");
const layout_support = @import("layout_support.zig");
const ClientLayoutBuilder = @This();

layout: Layout = .{},
/// The tree in pre-order, as the protocol carries it.
nodes: []const core.ClientLayoutNode,
next_index: usize = 0,

pub fn build(self: *ClientLayoutBuilder, parent: ?layout_support.NodeIndex) !layout_support.NodeIndex {
    if (self.next_index == self.nodes.len) {
        return error.InvalidClientLayoutTree;
    }

    if (self.next_index == layout_support.max_nodes) {
        return error.NodeLimitReached;
    }

    const encoded = self.nodes[self.next_index];

    const index: layout_support.NodeIndex = @intCast(self.next_index);
    self.next_index += 1;
    switch (encoded) {
        .pane => |pane| {
            self.layout.nodes[index] = .{
                .parent = parent,
                .node = .{
                    .leaf = pane.id,
                },
            };
            self.layout.pane_count += 1;
        },
        .split => |split| {
            self.layout.nodes[index] = .{
                .parent = parent,
            };
            const first = try self.build(index);
            const second = try self.build(index);
            self.layout.nodes[index].node = .{
                .split = .{
                    .axis = switch (split.axis) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .ratio = split.ratio,
                    .first = first,
                    .second = second,
                },
            };
        },
    }

    return index;
}
