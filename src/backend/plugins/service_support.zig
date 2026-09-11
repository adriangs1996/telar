//! Runtime tap actor set: one bounded sequential worker per trusted plugin.

const std = @import("std");
const core = @import("telar-core");
const effects = @import("effects.zig");
const protocol = @import("protocol.zig");
const proxy = @import("../proxy/root.zig");
const session_mod = @import("session_support.zig");

pub const Io = std.Io;
pub const Session = session_mod.Session;
pub const max_workers = 16;
pub const queue_depth = 64;
pub const restart_limit = 5;
pub const restart_window_ms = 10 * 60 * 1000;

pub const Spec = @import("ServiceSpec.zig");

pub const Package = @import("Package.zig");

const Frame = @import("Frame.zig");

const Worker = @import("Worker.zig");

pub const Service = @import("Service.zig");

pub fn requireCapability(spec: *const Spec, capability: core.plugin.Capability) !void {
    if (!spec.declared.contains(capability)) {
        return error.CapabilityNotDeclared;
    }
    if (!spec.granted.contains(capability)) {
        return error.CapabilityNotGranted;
    }
}

pub const InitOptions = @import("InitOptions.zig");

pub fn capturedBytes(captured: *const proxy.CaptureExchange) usize {
    var total: usize = 0;
    inline for (.{ captured.request, captured.response }) |optional| {
        if (optional) |half| {
            total +|= half.head.len +| half.body.len;
        }
    }
    return total;
}

test "effect authorization checks exact identity, declaration and grant" {
    var declared = core.plugin.CapabilitySet.initEmpty();
    declared.insert(.proxy_tap);
    declared.insert(.history_write);
    var granted = core.plugin.CapabilitySet.initEmpty();
    granted.insert(.proxy_tap);
    const digest = [_]u8{0x5a} ** 32;
    const spec = try Spec.init(0, 7, .{
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
    var result: effects.Result = .{
        .gpa = std.testing.allocator,
        .package_index = 0,
        .plugin_id = core.plugin.stableId("tap.test"),
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
    var result_storage: [1]*effects.Result = undefined;
    var results: Io.Queue(*effects.Result) = .init(&result_storage);
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
    var result_storage: [1]*effects.Result = undefined;
    var results: Io.Queue(*effects.Result) = .init(&result_storage);
    worker.init(.{ .gpa = std.testing.allocator, .spec = undefined, .results = &results });

    for (0..restart_limit) |_| worker.recordRestart(std.testing.io);

    try std.testing.expect(worker.disabled);
}
