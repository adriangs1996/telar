const OptionsType = @import("../../engine/Options.zig");
const ServiceType = @import("../../engine/Service.zig");
const engine = @import("engine.zig");
const std = @import("std");
const EngineRuntimeState = @import("EngineRuntimeState.zig");
const Runtime = @This();

lifecycle: engine.EngineLifecycle,

pub const Options = @import("../../engine/Options.zig");
pub const Service = @import("../../engine/Service.zig");

/// Creates the engine service at a stable address and starts its actor.
/// No child process starts until the first prompt.
///
/// ```zig
/// var engine_runtime = try Runtime.init(io, gpa, options);
/// defer engine_runtime.deinit();
/// ```
pub fn init(io: std.Io, gpa: std.mem.Allocator, options: OptionsType) !Runtime {
    const state = try gpa.create(EngineRuntimeState);
    const engine_service = ServiceType.init(gpa, options) catch |err| {
        gpa.destroy(state);
        return err;
    };
    state.* = .{
        .io = io,
        .gpa = gpa,
        .service = engine_service,
    };

    return .{ .lifecycle = try engine.EngineLifecycle.start(state) };
}

/// Borrows the service for as long as this runtime remains alive.
///
/// ```zig
/// const service = engine_runtime.service();
/// ```
pub fn service(runtime: *Runtime) *ServiceType {
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
