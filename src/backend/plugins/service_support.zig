//! Runtime tap actor set: one bounded sequential worker per trusted plugin.

const ServiceSpec = @import("ServiceSpec.zig");
const CapabilityType = @import("telar-core").Capability;
const Exchange = @import("../proxy/capture/Exchange.zig");
const CapabilitySetType = @import("telar-core").CapabilitySet;
const Service = @import("Service.zig");
const ResultType = @import("Result.zig");
const std = @import("std");
const stableId_module = @import("telar-core").stableId;
const Worker = @import("Worker.zig");
const Frame = @import("Frame.zig");

pub const max_workers = 16;
pub const queue_depth = 64;
pub const restart_limit = 5;
pub const restart_window_ms = 10 * 60 * 1000;

pub fn requireCapability(spec: *const ServiceSpec, capability: CapabilityType) !void {
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
    var declared = CapabilitySetType.initEmpty();
    declared.insert(.proxy_tap);
    declared.insert(.history_write);
    var granted = CapabilitySetType.initEmpty();
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
    var result: ResultType = .{
        .gpa = std.testing.allocator,
        .package_index = 0,
        .plugin_id = stableId_module("tap.test"),
        .digest = digest,
        .generation = 7,
        .event_id = 1,
        .pane = @enumFromInt(3),
        .pane_generation = 4,
        .storage = &storage,
        .batch = .{ .len = 1 },
    };
    result.batch.items[0] = .{ .record_command = .{
        .command = "pwd",
        .cwd = "/tmp",
        .provider = "test",
        .tool_call_id = "",
        .session = null,
        .exit_code = 0,
        .started_at_ms = 1,
        .duration_ms = 2,
        .redact = true,
    } };

    try std.testing.expectError(error.CapabilityNotGranted, service.authorize(&result));
    service.workers[0].spec.granted.insert(.history_write);
    try service.authorize(&result);
    result.batch.items[0] = .{ .notification = .{ .level = .info, .duration_ms = 1000, .title = "tap", .message = "done" } };
    try std.testing.expectError(error.CapabilityNotDeclared, service.authorize(&result));
    result.digest[0] ^= 0xff;
    try std.testing.expectError(error.StaleTapWorker, service.authorize(&result));
}

test "worker queue drops the oldest frame when full" {
    const io = std.testing.io;
    var result_storage: [1]*ResultType = undefined;
    var results: std.Io.Queue(*ResultType) = .init(&result_storage);
    var worker: Worker = undefined;
    worker.init(.{ .gpa = std.testing.allocator, .spec = undefined, .results = &results });
    defer worker.stop(io);

    for (0..queue_depth + 1) |index| {
        const frame = try std.testing.allocator.create(Frame);
        frame.* = .{
            .gpa = std.testing.allocator,
            .event_id = index,
            .pane = @enumFromInt(1),
            .pane_generation = 1,
            .storage = try std.testing.allocator.alloc(u8, 1),
            .len = 1,
        };
        worker.submit(io, frame);
    }

    try std.testing.expectEqual(@as(u64, 1), worker.dropped.load(.monotonic));
}

test "five restarts in one window disable a worker" {
    var worker: Worker = undefined;
    var result_storage: [1]*ResultType = undefined;
    var results: std.Io.Queue(*ResultType) = .init(&result_storage);
    worker.init(.{ .gpa = std.testing.allocator, .spec = undefined, .results = &results });

    for (0..restart_limit) |_| worker.recordRestart(std.testing.io);

    try std.testing.expect(worker.disabled);
}
