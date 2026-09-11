/// Declares cross-capability work requested by pane event handling.
///
/// ```zig
/// const dependencies: Dependencies(Application) = .{ ... };
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        schedule_agent_description: *const fn (*Application) void,
    };
}
