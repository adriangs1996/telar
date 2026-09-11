const OutboxContext = @This();
const frontend = @import("telar-frontend");
const std = @import("std");
outbox: *frontend.client.Outbox,
buffer: [4096]u8 = undefined,

fn init(gpa: std.mem.Allocator) !OutboxContext {
    const outbox = try gpa.create(frontend.client.Outbox);
    outbox.* = .{};
    return .{ .outbox = outbox };
}

fn deinit(context: *OutboxContext, gpa: std.mem.Allocator) void {
    gpa.destroy(context.outbox);
}
