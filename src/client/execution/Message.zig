//! Events the shared client handles itself, whichever adapter delivers them.
//! An adapter wraps it as one variant of its own event union and passes it
//! to `Client.update`.
const core = @import("telar-core");
const data = @import("model");
const BarUpdatesCompletion = @import("../bars/BarUpdatesCompletion.zig");
const config_reload = @import("../resources/config_reload.zig");

pub const Message = union(enum) {
    server: anyerror!*const data.RuntimeMessage,
    sent: anyerror!void,
    sidebar_animation_tick: anyerror!void,
    notification_tick: anyerror!void,
    bar_tick: anyerror!void,
    bar_command: BarUpdatesCompletion,
    plugin_result: data.PluginActionsCompletion,
    path_completion: data.PathCompletionCompletion,
    link_opened: anyerror!void,
    sound_played: anyerror!void,
    notified: anyerror!void,
    config_reload: anyerror!config_reload.ConfigReload,

    /// The budget the event runs under.
    /// Example: `const path = core.enter(message.path());`
    pub fn path(self: Message) core.Path {
        return switch (self) {
            .server, .sent, .sidebar_animation_tick => .interactive,
            .notification_tick, .bar_tick, .bar_command, .plugin_result, .path_completion, .link_opened, .sound_played, .notified, .config_reload => .observation,
        };
    }
};

test "client events keep their interactive and observation budgets" {
    const std = @import("std");
    try std.testing.expectEqual(core.Path.interactive, (Message{ .sent = {} }).path());
    try std.testing.expectEqual(core.Path.interactive, (Message{ .sidebar_animation_tick = {} }).path());
    try std.testing.expectEqual(core.Path.observation, (Message{ .notification_tick = {} }).path());
    try std.testing.expectEqual(core.Path.observation, (Message{ .bar_tick = {} }).path());
    try std.testing.expectEqual(core.Path.observation, (Message{ .link_opened = {} }).path());
}
