//! Runtime ownership for the optional headless agent engine.

const std = @import("std");
const EngineRuntimeState = @import("EngineRuntimeState.zig");
const ServiceType = @import("../../engine/Service.zig");
const GenericPort = @import("GenericPort.zig").Type;
const GenericLifecycle = @import("GenericLifecycle.zig").Type;
const EngineRuntime = @import("EngineRuntime.zig");
const types = @import("../../engine/types.zig");
const PromptType = @import("../../engine/Prompt.zig");

const Worker = std.Io.Future(anyerror!void);

fn startWorker(state: *EngineRuntimeState) !Worker {
    return state.io.concurrent(ServiceType.run, .{ &state.service, state.io });
}

fn stopService(state: *EngineRuntimeState) void {
    state.service.stop(state.io);
}

fn joinWorker(state: *EngineRuntimeState, worker: *Worker) void {
    _ = worker.await(state.io) catch {};
}

fn destroyState(state: *EngineRuntimeState) void {
    const gpa = state.gpa;
    state.service.deinit(state.io);
    gpa.destroy(state);
}

const lifecycle_port: GenericPort(EngineRuntimeState, Worker) = .{
    .start = startWorker,
    .close = stopService,
    .join = joinWorker,
    .destroy = destroyState,
};

pub const EngineLifecycle = GenericLifecycle(EngineRuntimeState, Worker, lifecycle_port);

fn createAndDestroy(gpa: std.mem.Allocator) !void {
    var runtime = try EngineRuntime.init(std.testing.io, gpa, .{
        .arguments = &.{"/definitely/not/a/telar-engine"},
        .timeout_ms = 1000,
        .idle_timeout_ms = 60_000,
    });
    runtime.deinit();
}

test "every allocation failure rolls back engine runtime ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndDestroy, .{});
}

test "the engine runtime answers through its actor and stops cleanly" {
    const io = std.testing.io;
    var runtime = try EngineRuntime.init(io, std.testing.allocator, .{
        .arguments = &.{"/definitely/not/a/telar-engine"},
        .timeout_ms = 1000,
        .idle_timeout_ms = 60_000,
    });
    defer runtime.deinit();

    const purpose: types.Purpose = .{ .suggestion = .{ .client_id = 1, .client_generation = 1, .request_id = 1 } };
    try std.testing.expect(runtime.service().submit(io, .{ .prompt = try PromptType.init(purpose, "suggest") }));
    const response = try runtime.service().receiveResponse(io);
    try std.testing.expectEqual(types.Status.unavailable, response.status);
}
