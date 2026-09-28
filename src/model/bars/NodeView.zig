//! One component with the text and samples it borrows from its list, and the
//! host facts built-in components read. Adapters paint from this value, so a
//! painter works the same for a bar slot, a tooltip and a panel.
const BarFacts = @import("BarFacts.zig");
const Node = @import("Node.zig");
const NodeView = @This();

index: u8,
node: Node,
text: []const u8,
detail: []const u8,
samples: []const u8,
facts: *const BarFacts,

/// Example: `const view = NodeView.of(content, index, &facts);`
pub fn of(content: anytype, index: usize, facts: *const BarFacts) NodeView {
    const node = content.slice()[index];
    return .{
        .index = @intCast(index),
        .node = node,
        .text = content.text(node.text),
        .detail = content.text(node.detail),
        .samples = content.samples(node),
        .facts = facts,
    };
}
