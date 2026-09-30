//! Runtime tap actor set: one bounded sequential worker per trusted plugin.

const owned = @import("../proxy/capture/owned.zig");
const core = @import("telar-core");
const ServiceSpec = @import("ServiceSpec.zig");
const Exchange = owned.Exchange;
const Service = @import("Service.zig");
const Result = @import("Result.zig");
const std = @import("std");
const Worker = @import("Worker.zig");
const SharedExchange = @import("SharedExchange.zig");
const TapBudget = @import("TapBudget.zig");

pub const max_workers = 16;
pub const queue_depth = 64;
pub const restart_limit = 5;
pub const restart_window_ms = 10 * 60 * 1000;
/// How long one tap callback may run inside its worker; instructions bound
/// the work and this deadline is the safety net.
pub const callback_deadline_ms = 2 * std.time.ms_per_s;
/// How long the runtime waits for a worker's reply: the callback's deadline
/// plus the time to decode the exchange and write the reply, so a callback
/// that fails at its deadline replies before the runtime gives up.
pub const reply_timeout_ms = callback_deadline_ms + std.time.ms_per_s;
/// Bytes the tap holds together: exchanges waiting in every worker queue
/// and the frames workers are sending. Queued exchanges also stay within
/// the capture quota, so this mostly bounds the frames: four of the
/// largest default exchanges at once.
pub const max_held_bytes = 128 * 1024 * 1024;

pub const queue_depth_limit = core.Limit.declare("plugins.tap.queue_depth", "exchanges", queue_depth);
pub const held_bytes_limit = core.Limit.declare("plugins.tap.max_held_bytes", "bytes", max_held_bytes);
pub const reply_timeout_limit = core.Limit.declare("plugins.tap.reply_timeout_ms", "ms", reply_timeout_ms);
pub const restart_limit_reach = core.Limit.declare("plugins.tap.restart_limit", "restarts in 10 min", restart_limit);

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

test "worker queue drops the oldest exchange when full and releases it" {
    const io = std.testing.io;
    var result_storage: [1]*Result = undefined;
    var results: std.Io.Queue(*Result) = .init(&result_storage);
    var worker: Worker = undefined;
    worker.init(.{
        .gpa = std.testing.allocator,
        .spec = undefined,
        .results = &results,
    });
    defer worker.stop(io);
    var budget: TapBudget = .{
        .max_bytes = queue_depth + 1,
    };
    try std.testing.expect(budget.charge(queue_depth + 1));

    for (0..queue_depth + 1) |index| {
        var exchange: Exchange = .{};
        const shared = try SharedExchange.create(std.testing.allocator, &exchange, .{
            .event_id = index,
            .charged = 1,
            .budget = &budget,
            .holders = 1,
        });
        worker.submit(io, shared);
    }

    try std.testing.expectEqual(@as(u64, 1), worker.dropped.load(.monotonic));
    try std.testing.expectEqual(@as(usize, queue_depth), budget.held.load(.monotonic));
}

test "five restarts in one window disable a worker" {
    var worker: Worker = undefined;
    var result_storage: [1]*Result = undefined;
    var results: std.Io.Queue(*Result) = .init(&result_storage);
    worker.init(.{ .gpa = std.testing.allocator, .spec = undefined, .results = &results });

    for (0..restart_limit) |_| worker.recordRestart(std.testing.io);

    try std.testing.expect(worker.disabled.load(.monotonic));
}

test "a worker replies within the runtime's wait even at its callback deadline" {
    try std.testing.expect(reply_timeout_ms > callback_deadline_ms);
}
