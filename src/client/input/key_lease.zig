//! Bounded ownership for host keys that report a physical lifecycle.

const GenericTable = @import("GenericTable.zig").Type;
const PhysicalType = @import("Physical.zig");
const std = @import("std");

const TestOwner = enum {
    binding,
    pane,
    prompt,
};

const TestTable = GenericTable(TestOwner, 2);

test "a physical identity keeps one replaceable owner" {
    const key: PhysicalType = .{ .value = 115 };
    var leases: TestTable = .{};

    try std.testing.expect(leases.acquire(key, .binding));
    try std.testing.expectEqual(TestOwner.binding, leases.owner(key).?);
    try std.testing.expect(leases.acquire(key, .pane));
    try std.testing.expectEqual(@as(usize, 1), leases.count());
    try std.testing.expectEqual(TestOwner.pane, leases.owner(key).?);
    try std.testing.expectEqual(TestOwner.pane, leases.release(key).?);
    try std.testing.expectEqual(@as(usize, 0), leases.count());
}

test "a full lease table fails closed and records saturation" {
    var leases: TestTable = .{};

    try std.testing.expect(leases.acquire(.{ .value = 1 }, .pane));
    try std.testing.expect(leases.acquire(.{ .value = 2 }, .prompt));
    try std.testing.expect(!leases.acquire(.{ .value = 3 }, .binding));
    try std.testing.expectEqual(@as(u64, 1), leases.overflowCount());
    try std.testing.expect(leases.owner(.{ .value = 3 }) == null);
}

test "release compacts storage without changing another owner" {
    var leases: TestTable = .{};

    try std.testing.expect(leases.acquire(.{ .value = 1 }, .binding));
    try std.testing.expect(leases.acquire(.{ .value = 2 }, .pane));
    try std.testing.expectEqual(TestOwner.binding, leases.release(.{ .value = 1 }).?);
    try std.testing.expectEqual(TestOwner.pane, leases.owner(.{ .value = 2 }).?);
    try std.testing.expect(leases.release(.{ .value = 1 }) == null);

    leases.clear();
    try std.testing.expectEqual(@as(usize, 0), leases.count());
}
