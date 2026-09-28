/// A configuration key only the retired terminal client honored. Loading a
/// file that still sets one ignores it and reports it, so an older file never
/// keeps Telar from starting (docs/configuration.md#retired-keys).
pub const RetiredConfigKey = enum {
    sidebar_renderer,
    terminal_delivery,
    escape_timeout,
    icons,

    /// The key as a file sets it.
    /// Example: `try writer.print("{s}", .{key.path()});`
    pub fn path(self: RetiredConfigKey) []const u8 {
        return switch (self) {
            .sidebar_renderer => "client.sidebar.renderer",
            .terminal_delivery => "client.notifications.delivery = \"terminal\"",
            .escape_timeout => "client.input.escape_timeout_ms",
            .icons => "client.icons",
        };
    }
};
