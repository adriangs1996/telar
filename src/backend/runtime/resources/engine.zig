//! Runtime ownership for the optional headless agent engine.

const std = @import("std");
const engine = @import("../../engine/root.zig");
const worker_lifecycle = @import("worker_lifecycle.zig");

const Io = std.Io;
const Worker = Io.Future(anyerror!void);

const RuntimeState = struct {
    io: Io,
    gpa: std.mem.Allocator,
    service: engine.Service,
};

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

const EngineLifecycle = worker_lifecycle.Lifecycle(RuntimeState, Worker, lifecycle_port);

pub const Runtime = struct {
    lifecycle: EngineLifecycle,

    pub const Options = engine.Options;
    pub const Service = engine.Service;

    /// Creates the engine service at a stable address and starts its actor.
    /// No child process starts until the first prompt.
    ///
    /// ```zig
    /// var engine_runtime = try Runtime.init(io, gpa, options);
    /// defer engine_runtime.deinit();
    /// ```
    pub fn init(io: Io, gpa: std.mem.Allocator, options: Options) !Runtime {
        const state = try gpa.create(RuntimeState);
        const engine_service = engine.Service.init(gpa, options) catch |err| {
            gpa.destroy(state);
            return err;
        };
        state.* = .{
            .io = io,
            .gpa = gpa,
            .service = engine_service,
        };

        return .{ .lifecycle = try EngineLifecycle.start(state) };
    }

    /// Borrows the service for as long as this runtime remains alive.
    ///
    /// ```zig
    /// const service = engine_runtime.service();
    /// ```
    pub fn service(runtime: *Runtime) *engine.Service {
        return &runtime.lifecycle.state.service;
    }

    /// Stops the actor, joins it, kills a live child and frees the rings.
    ///
    /// ```zig
    /// engine_runtime.deinit();
    /// ```
    pub fn deinit(runtime: *Runtime) void {
        runtime.lifecycle.deinit();
    }
};

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
