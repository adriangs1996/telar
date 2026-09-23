//! Events the shared client handles itself, whichever adapter delivers them.
//! An adapter wraps it as one variant of its own event union and passes it
//! to `AttachedClient.update`.
const core = @import("telar-core");
const data = @import("model");
const BarUpdatesCompletion = @import("../bars/BarUpdatesCompletion.zig");

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

    /// The budget the event runs under.
    /// Example: `const path = core.enter(message.path());`
    pub fn path(self: Message) core.Path {
        return switch (self) {
            .server, .sent, .sidebar_animation_tick => .interactive,
            .notification_tick, .bar_tick, .bar_command, .plugin_result, .path_completion, .link_opened => .observation,
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
