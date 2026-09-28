const client = @import("telar-client");
const mailbox = @import("mailbox");
const PresentationResult = @import("PresentationResult.zig");
const MachineMessage = @import("MachineMessage.zig");

pub const Message = union(enum) {
    client: client.Message,
    /// An event for the client of another machine the window holds.
    machine: MachineMessage,
    /// `machines.json` changed; carries its new fingerprint.
    profiles_changed: u64,
    input_ready,
    focus: bool,
    presented: PresentationResult,
    configuration_ready,
    binding_timeout: anyerror!void,
    favicon: client.FaviconCompletion,
    diagram_ready,
    syntax_ready,
    change_review_ready,
};

pub const Inbox = mailbox.GenericInbox(Message);
