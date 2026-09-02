//! Runtime ownership for the asynchronous history service.

const std = @import("std");
const history = @import("../../history/root.zig");
const worker_lifecycle = @import("worker_lifecycle.zig");

const Io = std.Io;
const Worker = Io.Future(anyerror!void);

const RuntimeState = struct {
    io: Io,
    gpa: std.mem.Allocator,
    service: history.Service,
};

fn startWorker(state: *RuntimeState) !Worker {
    return state.io.concurrent(history.Service.run, .{ &state.service, state.io });
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

const HistoryLifecycle = worker_lifecycle.Lifecycle(RuntimeState, Worker, lifecycle_port);

pub const Runtime = struct {
    lifecycle: HistoryLifecycle,

    pub const Config = history.Service.Config;

    /// Creates the history service at a stable address and starts its worker.
    /// A database-open failure keeps the service alive in degraded mode.
    ///
    /// ```zig
    /// var history_runtime = try Runtime.init(io, gpa, .{ .database_path = ":memory:" });
    /// defer history_runtime.deinit();
    /// ```
    pub fn init(io: Io, gpa: std.mem.Allocator, config: Config) !Runtime {
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

        return .{ .lifecycle = try HistoryLifecycle.start(state) };
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
};

fn createAndDestroy(gpa: std.mem.Allocator) !void {
    var runtime = try Runtime.init(std.testing.io, gpa, .{ .database_path = ":memory:" });
    runtime.deinit();
}

test "every allocation failure rolls back history runtime ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndDestroy, .{});
}

test "database open failure starts a queryable degraded worker" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/missing/history.db", .{directory_buffer[0..directory_len]});
    var runtime = try Runtime.init(io, std.testing.allocator, .{ .database_path = path });
    defer runtime.deinit();
    const service_value = runtime.service();

    try std.testing.expect(!service_value.statsSnapshot().available);
    try std.testing.expect(service_value.openError() != null);
    const query = try history.Query.init(.{
        .request_id = @enumFromInt(7),
        .origin = .{
            .client = .{ .id = 3, .generation = 5 },
            .close_after_reply = false,
        },
    });
    try std.testing.expect(service_value.query(io, query));
    const response = try service_value.receiveResponse(io);
    defer history.model.deinitResponse(response, std.testing.allocator);

    try std.testing.expect(response == .failed);
    try std.testing.expectEqualStrings("history database is unavailable", response.failed.message);
}
