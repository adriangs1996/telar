const client = @import("telar-client");

pub const Message = union(enum) {
    server: anyerror!*const client.RuntimeMessage,
    sent: anyerror!void,
    input_ready,
    focus: bool,
    presented: @import("PresentationResult.zig"),
    configuration_ready,
    input_timeout: anyerror!void,
    binding_timeout: anyerror!void,
    sidebar_animation_tick: anyerror!void,
    notification_tick: anyerror!void,
    bar_tick: anyerror!void,
    bar_command: client.BarUpdatesCompletion,
    plugin_result: client.PluginActionsCompletion,
};

pub const Inbox = client.GenericInbox(Message);
