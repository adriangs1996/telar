const ServiceConfig = @import("../../history/ServiceConfig.zig");
const history = @import("history.zig");
const std = @import("std");
const HistoryRuntimeState = @import("HistoryRuntimeState.zig");
const ServiceType = @import("../../history/Service.zig");
const Runtime = @This();

lifecycle: history.HistoryLifecycle,

pub const Config = @import("../../history/ServiceConfig.zig");

/// Creates the history service at a stable address and starts its worker.
/// A database-open failure keeps the service alive in degraded mode.
///
/// ```zig
/// var history_runtime = try Runtime.init(io, gpa, .{ .database_path = ":memory:" });
/// defer history_runtime.deinit();
/// ```
pub fn init(io: std.Io, gpa: std.mem.Allocator, config: ServiceConfig) !Runtime {
    const state = try gpa.create(HistoryRuntimeState);
    const history_service = ServiceType.init(gpa, config) catch |err| {
        gpa.destroy(state);
        return err;
    };
    state.* = .{
        .io = io,
        .gpa = gpa,
        .service = history_service,
    };

    return .{ .lifecycle = try history.HistoryLifecycle.start(state) };
}

/// Borrows the history service for as long as this runtime remains alive.
///
/// ```zig
/// const service = history_runtime.service();
/// ```
pub fn service(runtime: *Runtime) *ServiceType {
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
