const SessionType = @import("../../client/Session.zig");
const TerminalColorsType = @import("telar-core").TerminalColors;

/// Example: `var handler: Handler(Application) = .{ .application = app, .session = session };`.
pub fn Type(comptime Application: type) type {
    return struct {
        application: *Application,
        session: *SessionType,

        /// Example: `handler.execute(colors);`.
        pub fn execute(handler: *@This(), colors: TerminalColorsType) void {
            if (handler.session.setTerminalColors(colors)) {
                handler.application.refreshTerminalColors(handler.session.key);
            }
        }
    };
}
