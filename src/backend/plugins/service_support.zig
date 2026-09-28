//! Runtime tap actor set: one bounded sequential worker per trusted plugin.

const owned = @import("../proxy/capture/owned.zig");
const core = @import("telar-core");
const ServiceSpec = @import("ServiceSpec.zig");
const Exchange = owned.Exchange;
const Service = @import("Service.zig");
const Result = @import("Result.zig");
const std = @import("std");
const Worker = @import("Worker.zig");
const Frame = @import("Frame.zig");

pub const max_workers = 16;
pub const queue_depth = 64;
pub const restart_limit = 5;
pub const restart_window_ms = 10 * 60 * 1000;

pub fn requireCapability(spec: *const ServiceSpec, capability: core.Capability) !void {
    if (!spec.declared.contains(capability)) {
        return error.CapabilityNotDeclared;
    }
    if (!spec.granted.contains(capability)) {
        return error.CapabilityNotGranted;
    }
}

pub fn capturedBytes(captured: *const Exchange) usize {
    var total: usize = 0;
    inline for (.{ captured.request, captured.response }) |optional| {
        if (optional) |half| {
            total +|= half.head.len +| half.body.len;
        }
    }
    return total;
}

test "effect authorization checks exact identity, declaration and grant" {
    var declared = core.CapabilitySet.initEmpty();
    declared.insert(.proxy_tap);
    declared.insert(.notifications);
    var granted = core.CapabilitySet.initEmpty();
    granted.insert(.proxy_tap);
    const digest = [_]u8{0x5a} ** 32;
    const spec = try ServiceSpec.init(0, 7, .{
        .id = "tap.test",
        .entry = "/tmp/main.lua",
        .digest = digest,
        .declared = declared,
        .granted = granted,
    });
    var service: Service = undefined;
    service.worker_count = 1;
    service.workers[0].spec = spec;
    var storage: [1]u8 = .{0};
    var result: Result = .{
        .gpa = std.testing.allocator,
        .package_index = 0,
        .plugin_id = core.stableId("tap.test"),
        .digest = digest,
        .generation = 7,
        .event_id = 1,
        .storage = &storage,
        .batch = .{ .len = 1 },
    };
    result.batch.items[0] = .{ .notification = .{ .level = .info, .duration_ms = 1000, .title = "tap", .message = "done" } };

    try std.testing.expectError(error.CapabilityNotGranted, service.authorize(&result));
    service.workers[0].spec.granted.insert(.notifications);
    try service.authorize(&result);
    service.workers[0].spec.declared.remove(.notifications);
    try std.testing.expectError(error.CapabilityNotDeclared, service.authorize(&result));
    service.workers[0].spec.declared.insert(.notifications);
    result.digest[0] ^= 0xff;
    try std.testing.expectError(error.StaleTapWorker, service.authorize(&result));
}

test "worker queue drops the oldest frame when full" {
    const io = std.testing.io;
    var result_storage: [1]*Result = undefined;
    var results: std.Io.Queue(*Result) = .init(&result_storage);
    var worker: Worker = undefined;
    worker.init(.{ .gpa = std.testing.allocator, .spec = undefined, .results = &results });
    defer worker.stop(io);

    for (0..queue_depth + 1) |index| {
        const frame = try std.testing.allocator.create(Frame);
        frame.* = .{
            .gpa = std.testing.allocator,
            .event_id = index,
            .storage = try std.testing.allocator.alloc(u8, 1),
            .len = 1,
        };
        worker.submit(io, frame);
    }

    try std.testing.expectEqual(@as(u64, 1), worker.dropped.load(.monotonic));
}

test "five restarts in one window disable a worker" {
    var worker: Worker = undefined;
    var result_storage: [1]*Result = undefined;
    var results: std.Io.Queue(*Result) = .init(&result_storage);
    worker.init(.{ .gpa = std.testing.allocator, .spec = undefined, .results = &results });

    for (0..restart_limit) |_| worker.recordRestart(std.testing.io);

    try std.testing.expect(worker.disabled);
}
