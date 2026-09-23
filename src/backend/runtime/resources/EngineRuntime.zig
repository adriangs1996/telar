const std = @import("std");
const types = @import("../../engine/types.zig");
const Prompt = @import("../../engine/Prompt.zig");
/// Owns the optional headless engine service at a stable heap address and
/// the one actor that runs it. No child process starts until the first
/// prompt; teardown stops the service before joining and destroying it.
const EngineRuntime = @This();

pub const Options = @import("../../engine/Options.zig");
pub const Service = @import("../../engine/Service.zig");

const Worker = std.Io.Future(anyerror!void);

io: std.Io,
gpa: std.mem.Allocator,
service_value: *Service,
worker: Worker,

/// Creates the engine service and starts its actor. An actor that cannot
/// start releases the service before the error returns.
///
/// ```zig
/// var engine_runtime = try EngineRuntime.init(io, gpa, options);
/// defer engine_runtime.deinit();
/// ```
pub fn init(io: std.Io, gpa: std.mem.Allocator, options: Options) !EngineRuntime {
    const service_value = try gpa.create(Service);
    errdefer gpa.destroy(service_value);

    service_value.* = try Service.init(gpa, options);
    errdefer service_value.deinit(io);

    return .{
        .io = io,
        .gpa = gpa,
        .service_value = service_value,
        .worker = try io.concurrent(Service.run, .{ service_value, io }),
    };
}

/// Borrows the service for as long as this runtime remains alive.
///
/// ```zig
/// const service = engine_runtime.service();
/// ```
pub fn service(self: *EngineRuntime) *Service {
    return self.service_value;
}

/// Stops the actor, joins it, kills a live child and frees the rings.
///
/// ```zig
/// engine_runtime.deinit();
/// ```
pub fn deinit(self: *EngineRuntime) void {
    self.service_value.stop(self.io);
    _ = self.worker.await(self.io) catch {};
    self.service_value.deinit(self.io);
    self.gpa.destroy(self.service_value);
}

const test_options: Options = .{
    .arguments = &.{"/definitely/not/a/telar-engine"},
    .timeout_ms = 1000,
    .idle_timeout_ms = 60_000,
};

fn createAndDestroy(gpa: std.mem.Allocator) !void {
    var runtime = try EngineRuntime.init(std.testing.io, gpa, test_options);
    runtime.deinit();
}

test "every allocation failure rolls back engine runtime ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndDestroy, .{});
}

test "an engine actor that cannot start releases the engine service" {
    try std.testing.expectError(error.ConcurrencyUnavailable, EngineRuntime.init(std.Io.failing, std.testing.allocator, test_options));
}

test "the engine runtime answers through its actor and stops cleanly" {
    const io = std.testing.io;
    var runtime = try EngineRuntime.init(io, std.testing.allocator, test_options);
    defer runtime.deinit();

    const purpose: types.Purpose = .{ .suggestion = .{ .client_id = 1, .client_generation = 1, .request_id = 1 } };
    try std.testing.expect(runtime.service().submit(io, .{ .prompt = try Prompt.init(purpose, "suggest") }));
    const response = try runtime.service().receiveResponse(io);
    try std.testing.expectEqual(types.Status.unavailable, response.status);
}
