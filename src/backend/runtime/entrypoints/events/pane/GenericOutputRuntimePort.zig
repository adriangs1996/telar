const PaneType = @import("../../../../pane/Pane.zig");
const OutputIngest = @import("OutputIngest.zig");
const PaneIdType = @import("telar-core").PaneId;

/// Defines the schedulers, client-state query, and lifecycle effects bound by
/// the runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        schedule_observation: *const fn (*Context, *PaneType) anyerror!void,
        schedule_media: *const fn (*Context, *PaneType) anyerror!void,
        start_ingest: *const fn (*Context, OutputIngest) anyerror!void,
        has_outstanding_frame: *const fn (*Context, PaneIdType) bool,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}
