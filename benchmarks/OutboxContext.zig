const OutboxType = @import("telar-client").Outbox;
const std = @import("std");
const OutboxContext = @This();

outbox: *OutboxType,
buffer: [4096]u8 = undefined,

pub fn init(gpa: std.mem.Allocator) !OutboxContext {
    const outbox = try gpa.create(OutboxType);
    outbox.* = .{};
    return .{ .outbox = outbox };
}

pub fn deinit(context: *OutboxContext, gpa: std.mem.Allocator) void {
    gpa.destroy(context.outbox);
}
