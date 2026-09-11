const PluginsRuntimeInitOptions = @import("PluginsRuntimeInitOptions.zig");
const ServiceType = @import("../../plugins/Service.zig");
const Runtime = @This();

service_value: ServiceType,

pub const InitOptions = @import("PluginsRuntimeInitOptions.zig");

/// Starts every configured tap worker actor at one stable address.
///
/// ```zig
/// var runtime: Runtime = undefined;
/// try runtime.init(.{ .io = io, .gpa = gpa, .specs = specs });
/// ```
pub fn init(runtime: *Runtime, options: PluginsRuntimeInitOptions) !void {
    try runtime.service_value.init(.{ .io = options.io, .gpa = options.gpa, .specs = options.specs });
}

/// Borrows the worker service while the runtime resource is alive.
///
/// ```zig
/// const service = runtime.service();
/// ```
pub fn service(runtime: *Runtime) *ServiceType {
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
