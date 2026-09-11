const PaneType = @import("../../../../pane/Pane.zig");

/// Declares the follow-up operations required by pane projections.
///
/// ```zig
/// const dependencies: Dependencies(Application) = .{ ... };
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        schedule_description: *const fn (*Application) void,
        schedule_response: *const fn (*Application, *PaneType) anyerror!void,
    };
}
