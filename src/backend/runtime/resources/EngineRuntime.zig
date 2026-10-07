const std = @import("std");
const pi_rpc = @import("pi_rpc");
const EnginePurpose = @import("../EnginePurpose.zig").EnginePurpose;
const GenericService = pi_rpc.GenericService;
/// Owns the optional headless engine service at a stable heap address and
/// the one actor that runs it. No child process starts until the first
/// prompt; teardown stops the service before joining and destroying it.
const EngineRuntime = @This();

const Options = pi_rpc.Options;
pub const Service = GenericService(EnginePurpose);

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
    // The service has been stopped; join its actor before freeing its child and rings even if the actor returned an error.
    _ = self.worker.await(self.io) catch {};
    self.service_value.deinit(self.io);
    self.gpa.destroy(self.service_value);
}
