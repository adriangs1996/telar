//! Runtime ownership for the asynchronous history service.

const std = @import("std");
const history = @import("../../history/root.zig");
const worker_lifecycle = @import("worker_lifecycle.zig");

pub const Io = std.Io;
const Worker = Io.Future(anyerror!void);

const RuntimeState = @import("HistoryRuntimeState.zig");

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

pub const HistoryLifecycle = worker_lifecycle.Lifecycle(RuntimeState, Worker, lifecycle_port);

pub const Runtime = @import("HistoryRuntime.zig");

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
