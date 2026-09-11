const PaneType = @import("../../../../pane/Pane.zig");
const Read = @import("Read.zig");

/// Defines the asynchronous work and runtime lifecycle effects used after VT
/// ingestion.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        schedule_observation: *const fn (*Context, *PaneType) anyerror!void,
        schedule_media: *const fn (*Context, *PaneType) anyerror!void,
        refresh_clients: *const fn (*Context, *PaneType) void,
        schedule_response: *const fn (*Context, *PaneType) anyerror!void,
        start_read: *const fn (*Context, Read) anyerror!void,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}
