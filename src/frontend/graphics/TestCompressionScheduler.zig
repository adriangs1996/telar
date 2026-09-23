const Compression = @import("Compression.zig");
const std = @import("std");
const delivery = @import("kitty_delivery.zig");
const TestCompressionScheduler = @This();

pending: ?*Compression = null,

pub fn schedule(context: *anyopaque, job: *Compression) anyerror!void {
    const scheduler: *TestCompressionScheduler = @ptrCast(@alignCast(context));
    try std.testing.expect(scheduler.pending == null);
    scheduler.pending = job;
}

pub fn complete(self: *TestCompressionScheduler, store: *delivery.Store) void {
    const job = self.pending orelse return;
    delivery.completeCompression(store, Compression.run(job));
    self.pending = null;
}
