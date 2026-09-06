//! Commits one client's terminal defaults before updating its owned workspaces.

const core = @import("telar-core");
const client = @import("../../client/root.zig");

/// Example: `var handler: Handler(Application) = .{ .application = app, .session = session };`.
pub fn Handler(comptime Application: type) type {
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
