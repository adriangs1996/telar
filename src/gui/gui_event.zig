const client = @import("telar-client");

pub const Message = union(enum) {
    server: anyerror!*const client.RuntimeMessage,
    sent: anyerror!void,
    input_ready,
    focus: bool,
    presented: @import("PresentationResult.zig"),
    configuration_ready,
};

pub const Inbox = client.GenericInbox(Message);
