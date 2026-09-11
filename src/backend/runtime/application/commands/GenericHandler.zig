const client = @import("../../client/root.zig");
const core = @import("telar-core");
/// Example: `var handler: Handler(Application) = .{ .application = app, .session = session };`.
pub fn Type(comptime Application: type) type {
    return struct {
        application: *Application,
        session: *client.session.Session,

        /// Example: `handler.execute(colors);`.
        pub fn execute(handler: *@This(), colors: core.schema.TerminalColors) void {
            if (handler.session.setTerminalColors(colors)) {
                handler.application.refreshTerminalColors(handler.session.key);
            }
        }
    };
}
