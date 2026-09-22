const client = @import("telar-client");
const std = @import("std");
const OutboxContext = @This();

outbox: *client.Outbox,
buffer: [4096]u8 = undefined,

pub fn init(gpa: std.mem.Allocator) !OutboxContext {
    const outbox = try gpa.create(client.Outbox);
    outbox.* = .{};
    return .{ .outbox = outbox };
}

pub fn deinit(context: *OutboxContext, gpa: std.mem.Allocator) void {
    gpa.destroy(context.outbox);
}
