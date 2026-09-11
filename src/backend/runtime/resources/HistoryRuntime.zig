const Runtime = @This();
const source_namespace = @import("history.zig");
const history = @import("../../history/root.zig");
const std = @import("std");
const RuntimeState = @import("HistoryRuntimeState.zig");
lifecycle: source_namespace.HistoryLifecycle,

pub const Config = history.Service.Config;

/// Creates the history service at a stable address and starts its worker.
/// A database-open failure keeps the service alive in degraded mode.
///
/// ```zig
/// var history_runtime = try Runtime.init(io, gpa, .{ .database_path = ":memory:" });
/// defer history_runtime.deinit();
/// ```
pub fn init(io: source_namespace.Io, gpa: std.mem.Allocator, config: Config) !Runtime {
    const state = try gpa.create(RuntimeState);
    const history_service = history.Service.init(gpa, config) catch |err| {
        gpa.destroy(state);
        return err;
    };
    state.* = .{
        .io = io,
        .gpa = gpa,
        .service = history_service,
    };

    return .{ .lifecycle = try source_namespace.HistoryLifecycle.start(state) };
}

/// Borrows the history service for as long as this runtime remains alive.
///
/// ```zig
/// const service = history_runtime.service();
/// ```
pub fn service(runtime: *Runtime) *history.Service {
    return &runtime.lifecycle.state.service;
}

/// Stops the service, joins its worker, and releases every value still
/// owned by the history runtime.
///
/// ```zig
/// history_runtime.deinit();
/// ```
pub fn deinit(runtime: *Runtime) void {
    runtime.lifecycle.deinit();
}
