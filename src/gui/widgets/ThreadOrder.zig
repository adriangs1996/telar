//! Stable depth-first presentation over provider items that may arrive out of order.
const core = @import("telar-core");
const Order = @This();

indices: [core.agent_thread.max_items]u8 = undefined,
len: usize = 0,
visited: [core.agent_thread.max_items]bool = @splat(false),

/// Parents precede descendants; independent roots keep their arrival order.
/// Missing parents and cycles retain every row through a bounded final pass.
/// Example: `const order = ThreadOrder.resolve(snapshot.items());`
pub fn resolve(items: []const core.AgentThreadItem) Order {
    var order: Order = .{};
    for (items, 0..) |item, index| {
        const parent_exists = for (items) |candidate| {
            if (item.parent_identity != 0 and candidate.identity == item.parent_identity) {
                break true;
            }
        } else false;
        if (!parent_exists) {
            order.appendTree(items, index);
        }
    }

    for (0..items.len) |index| {
        order.appendTree(items, index);
    }

    return order;
}

fn appendTree(order: *Order, items: []const core.AgentThreadItem, index: usize) void {
    if (order.visited[index]) {
        return;
    }

    order.visited[index] = true;
    order.indices[order.len] = @intCast(index);
    order.len += 1;
    const identity = items[index].identity;
    if (identity == 0) {
        return;
    }

    for (items, 0..) |item, child| {
        if (item.parent_identity == identity) {
            order.appendTree(items, child);
        }
    }
}

test "children arriving before dispatch remain below their actual parent" {
    const std = @import("std");
    const items = [_]core.AgentThreadItem{
        .{ .identity = 1, .role = .user },
        .{ .identity = 3, .parent_identity = 2, .role = .tool, .kind = .subagent },
        .{ .identity = 2, .role = .tool, .kind = .dispatch },
        .{ .identity = 5, .parent_identity = 4, .role = .tool, .kind = .subagent },
        .{ .identity = 4, .role = .tool, .kind = .dispatch },
    };
    const order = Order.resolve(&items);
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1, 4, 3 }, order.indices[0..order.len]);
}

test "cyclic orphaned and nested activity retains every item once" {
    const std = @import("std");
    const items = [_]core.AgentThreadItem{
        .{ .identity = 1, .parent_identity = 2, .role = .tool },
        .{ .identity = 2, .parent_identity = 1, .role = .tool },
        .{ .identity = 3, .parent_identity = 99, .role = .tool },
        .{ .identity = 4, .parent_identity = 3, .role = .tool },
        .{ .identity = 5, .parent_identity = 4, .role = .tool },
    };
    const order = Order.resolve(&items);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 0, 1 }, order.indices[0..order.len]);
}
