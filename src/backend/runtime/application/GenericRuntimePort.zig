const source_namespace = @import("request_dispatch.zig");
/// Declares the pane schedulers that request handlers may invoke after a
/// successful command.
///
/// ```zig
/// const Port = RuntimePort(Application);
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        schedule_observation: *const fn (*Application, *source_namespace.Pane) anyerror!void,
        schedule_media: *const fn (*Application, *source_namespace.Pane) anyerror!void,
        schedule_response: *const fn (*Application, *source_namespace.Pane) anyerror!void,
        schedule_input: *const fn (*Application, *source_namespace.Pane) anyerror!void,
    };
}
