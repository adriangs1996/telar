const Runtime = @This();
const source_namespace = @import("engine.zig");
const engine = @import("../../engine/root.zig");
const std = @import("std");
const RuntimeState = @import("EngineRuntimeState.zig");
lifecycle: source_namespace.EngineLifecycle,

pub const Options = engine.Options;
pub const Service = engine.Service;

/// Creates the engine service at a stable address and starts its actor.
/// No child process starts until the first prompt.
///
/// ```zig
/// var engine_runtime = try Runtime.init(io, gpa, options);
/// defer engine_runtime.deinit();
/// ```
pub fn init(io: source_namespace.Io, gpa: std.mem.Allocator, options: Options) !Runtime {
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

    return .{ .lifecycle = try source_namespace.EngineLifecycle.start(state) };
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
