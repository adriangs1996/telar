const source_namespace = @import("pipeline.zig");
/// Declares the follow-up operations required while processing pane output.
///
/// ```zig
/// const dependencies: Dependencies(Application) = .{ ... };
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        schedule_observation: *const fn (*Application, *source_namespace.Pane) anyerror!void,
        schedule_media: *const fn (*Application, *source_namespace.Pane) anyerror!void,
        schedule_response: *const fn (*Application, *source_namespace.Pane) anyerror!void,
    };
}
