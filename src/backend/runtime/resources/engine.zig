//! Runtime ownership for the optional headless agent engine.

const std = @import("std");
const engine = @import("../../engine/root.zig");
const worker_lifecycle = @import("worker_lifecycle.zig");

pub const Io = std.Io;
const Worker = Io.Future(anyerror!void);

const RuntimeState = @import("EngineRuntimeState.zig");

fn startWorker(state: *RuntimeState) !Worker {
    return state.io.concurrent(engine.Service.run, .{ &state.service, state.io });
}

fn stopService(state: *RuntimeState) void {
    state.service.stop(state.io);
}

fn joinWorker(state: *RuntimeState, worker: *Worker) void {
    _ = worker.await(state.io) catch {};
}

fn destroyState(state: *RuntimeState) void {
    const gpa = state.gpa;
    state.service.deinit(state.io);
    gpa.destroy(state);
}

const lifecycle_port: worker_lifecycle.Port(RuntimeState, Worker) = .{
    .start = startWorker,
    .close = stopService,
    .join = joinWorker,
    .destroy = destroyState,
};

pub const EngineLifecycle = worker_lifecycle.Lifecycle(RuntimeState, Worker, lifecycle_port);

pub const Runtime = @import("EngineRuntime.zig");

fn createAndDestroy(gpa: std.mem.Allocator) !void {
    var runtime = try Runtime.init(std.testing.io, gpa, .{
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
    var runtime = try Runtime.init(io, std.testing.allocator, .{
        .arguments = &.{"/definitely/not/a/telar-engine"},
        .timeout_ms = 1000,
        .idle_timeout_ms = 60_000,
    });
    defer runtime.deinit();

    const purpose: engine.Purpose = .{ .suggestion = .{ .client_id = 1, .client_generation = 1, .request_id = 1 } };
    try std.testing.expect(runtime.service().submit(io, .{ .prompt = try engine.Prompt.init(purpose, "suggest") }));
    const response = try runtime.service().receiveResponse(io);
    try std.testing.expectEqual(engine.Status.unavailable, response.status);
}
