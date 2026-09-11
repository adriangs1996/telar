const Runtime = @This();
const plugins = @import("../../plugins/root.zig");
const source_namespace = @import("plugins.zig");
const std = @import("std");
service_value: plugins.Service,

pub const InitOptions = struct {
    io: source_namespace.Io,
    gpa: std.mem.Allocator,
    specs: []const plugins.Spec,
};

/// Starts every configured tap worker actor at one stable address.
///
/// ```zig
/// var runtime: Runtime = undefined;
/// try runtime.init(.{ .io = io, .gpa = gpa, .specs = specs });
/// ```
pub fn init(runtime: *Runtime, options: InitOptions) !void {
    try runtime.service_value.init(.{ .io = options.io, .gpa = options.gpa, .specs = options.specs });
}

/// Borrows the worker service while the runtime resource is alive.
///
/// ```zig
/// const service = runtime.service();
/// ```
pub fn service(runtime: *Runtime) *plugins.Service {
    return &runtime.service_value;
}

/// Stops every worker and releases its bounded queues.
///
/// ```zig
/// runtime.deinit();
/// ```
pub fn deinit(runtime: *Runtime) void {
    runtime.service_value.deinit();
}
