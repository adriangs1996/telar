const data = @import("model");
const client = @import("telar-client");
const std = @import("std");
const OutboxContext = @This();

outbox: *data.Outbox,
buffer: [4096]u8 = undefined,

pub fn init(gpa: std.mem.Allocator) !OutboxContext {
    const outbox = try gpa.create(data.Outbox);
    errdefer gpa.destroy(outbox);
    outbox.* = try .init(gpa);
    return .{ .outbox = outbox };
}

pub fn deinit(context: *OutboxContext, gpa: std.mem.Allocator) void {
    context.outbox.deinit(gpa);
    gpa.destroy(context.outbox);
}
