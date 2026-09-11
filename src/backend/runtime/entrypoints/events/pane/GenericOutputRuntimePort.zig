const source_namespace = @import("output.zig");
const Ingest = @import("OutputIngest.zig");
/// Defines the schedulers, client-state query, and lifecycle effects bound by
/// the runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        schedule_observation: *const fn (*Context, *source_namespace.Pane) anyerror!void,
        schedule_media: *const fn (*Context, *source_namespace.Pane) anyerror!void,
        start_ingest: *const fn (*Context, Ingest) anyerror!void,
        has_outstanding_frame: *const fn (*Context, source_namespace.schema.PaneId) bool,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}
