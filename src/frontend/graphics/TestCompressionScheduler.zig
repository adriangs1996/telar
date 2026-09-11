const TestCompressionScheduler = @This();
const Compression = @import("Compression.zig");
const std = @import("std");
const source_namespace = @import("kitty.zig");
const delivery = @import("kitty_delivery.zig");
pending: ?*Compression = null,

pub fn schedule(context: *anyopaque, job: *Compression) anyerror!void {
    const scheduler: *TestCompressionScheduler = @ptrCast(@alignCast(context));
    try std.testing.expect(scheduler.pending == null);
    scheduler.pending = job;
}

pub fn complete(scheduler: *TestCompressionScheduler, store: *source_namespace.Store) void {
    const job = scheduler.pending orelse return;
    delivery.completeCompression(store, Compression.run(job));
    scheduler.pending = null;
}
