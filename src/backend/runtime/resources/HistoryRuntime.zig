const std = @import("std");
const HistoryService = @import("../../history/Service.zig");
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
    // The service has been stopped; join its worker before freeing it even if that worker returned an error.
    _ = self.worker.await(self.io) catch {};
    self.service_value.deinit(self.io);
    self.gpa.destroy(self.service_value);
}
