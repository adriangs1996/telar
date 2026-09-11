const PaneType = @import("../../../../pane/Pane.zig");

/// Declares the follow-up operations required while processing pane output.
///
/// ```zig
/// const dependencies: Dependencies(Application) = .{ ... };
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        schedule_observation: *const fn (*Application, *PaneType) anyerror!void,
        schedule_media: *const fn (*Application, *PaneType) anyerror!void,
        schedule_response: *const fn (*Application, *PaneType) anyerror!void,
    };
}
