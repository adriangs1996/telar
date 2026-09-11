//! Runtime ownership for the asynchronous history service.

const std = @import("std");
const HistoryRuntimeState = @import("HistoryRuntimeState.zig");
const ServiceType = @import("../../history/Service.zig");
const GenericPort = @import("GenericPort.zig").Type;
const GenericLifecycle = @import("GenericLifecycle.zig").Type;
const HistoryRuntime = @import("HistoryRuntime.zig");
const QueryType = @import("../../history/Query.zig");
const model_module = @import("../../history/model.zig");

const Worker = std.Io.Future(anyerror!void);

fn startWorker(state: *HistoryRuntimeState) !Worker {
    return state.io.concurrent(ServiceType.run, .{ &state.service, state.io });
}

fn stopService(state: *HistoryRuntimeState) void {
    state.service.stop(state.io);
}

fn joinWorker(state: *HistoryRuntimeState, worker: *Worker) void {
    _ = worker.await(state.io) catch {};
}

fn destroyState(state: *HistoryRuntimeState) void {
    const gpa = state.gpa;
    state.service.deinit(state.io);
    gpa.destroy(state);
}

const lifecycle_port: GenericPort(HistoryRuntimeState, Worker) = .{
    .start = startWorker,
    .close = stopService,
    .join = joinWorker,
    .destroy = destroyState,
};

pub const HistoryLifecycle = GenericLifecycle(HistoryRuntimeState, Worker, lifecycle_port);

fn createAndDestroy(gpa: std.mem.Allocator) !void {
    var runtime = try HistoryRuntime.init(std.testing.io, gpa, .{ .database_path = ":memory:" });
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
    var runtime = try HistoryRuntime.init(io, std.testing.allocator, .{ .database_path = path });
    defer runtime.deinit();
    const service_value = runtime.service();

    try std.testing.expect(!service_value.statsSnapshot().available);
    try std.testing.expect(service_value.openError() != null);
    const query = try QueryType.init(.{
        .request_id = @enumFromInt(7),
        .origin = .{
            .client = .{ .id = 3, .generation = 5 },
            .close_after_reply = false,
        },
    });
    try std.testing.expect(service_value.query(io, query));
    const response = try service_value.receiveResponse(io);
    defer model_module.deinitResponse(response, std.testing.allocator);

    try std.testing.expect(response == .failed);
    try std.testing.expectEqualStrings("history database is unavailable", response.failed.message);
}
