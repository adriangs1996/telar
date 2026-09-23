const std = @import("std");
const HistoryService = @import("../../history/Service.zig");
const Query = @import("../../history/Query.zig");
const history_model = @import("../../history/model.zig");
/// Owns the history service at a stable heap address and the one worker
/// that runs it. Teardown stops the service's queues before joining the
/// worker, then destroys the service.
const HistoryRuntime = @This();

pub const Config = @import("../../history/ServiceConfig.zig");

const Worker = std.Io.Future(anyerror!void);

io: std.Io,
gpa: std.mem.Allocator,
service_value: *HistoryService,
worker: Worker,

/// Creates the history service and starts its worker. A database-open
/// failure keeps the service alive in degraded mode; a worker that cannot
/// start releases the service before the error returns.
///
/// ```zig
/// var history_runtime = try HistoryRuntime.init(io, gpa, .{ .database_path = ":memory:" });
/// defer history_runtime.deinit();
/// ```
pub fn init(io: std.Io, gpa: std.mem.Allocator, config: Config) !HistoryRuntime {
    const service_value = try gpa.create(HistoryService);
    errdefer gpa.destroy(service_value);

    service_value.* = try HistoryService.init(gpa, config);
    errdefer service_value.deinit(io);

    return .{
        .io = io,
        .gpa = gpa,
        .service_value = service_value,
        .worker = try io.concurrent(HistoryService.run, .{ service_value, io }),
    };
}

/// Borrows the history service for as long as this runtime remains alive.
///
/// ```zig
/// const service = history_runtime.service();
/// ```
pub fn service(self: *HistoryRuntime) *HistoryService {
    return self.service_value;
}

/// Stops the service, joins its worker and releases the service.
///
/// ```zig
/// history_runtime.deinit();
/// ```
pub fn deinit(self: *HistoryRuntime) void {
    self.service_value.stop(self.io);
    _ = self.worker.await(self.io) catch {};
    self.service_value.deinit(self.io);
    self.gpa.destroy(self.service_value);
}

fn createAndDestroy(gpa: std.mem.Allocator) !void {
    var runtime = try HistoryRuntime.init(std.testing.io, gpa, .{ .database_path = ":memory:" });
    runtime.deinit();
}

test "every allocation failure rolls back history runtime ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndDestroy, .{});
}

test "a worker that cannot start releases the history service" {
    try std.testing.expectError(
        error.ConcurrencyUnavailable,
        HistoryRuntime.init(std.Io.failing, std.testing.allocator, .{ .database_path = ":memory:" }),
    );
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
    const query = try Query.init(.{
        .request_id = @enumFromInt(7),
        .origin = .{
            .client = .{ .id = 3, .generation = 5 },
            .close_after_reply = false,
        },
    });
    try std.testing.expect(service_value.query(io, query));
    const response = try service_value.receiveResponse(io);
    defer history_model.deinitResponse(response, std.testing.allocator);

    try std.testing.expect(response == .failed);
    try std.testing.expectEqualStrings("history database is unavailable", response.failed.message);
}
