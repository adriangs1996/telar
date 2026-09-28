const std = @import("std");
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

    /// Tickets one machine's client holds at most for its link and timers:
    /// a runtime read, a runtime write and one wait per timer kind, each
    /// armed once at most, plus a connection attempt and a sound, which
    /// never overlap their own kind either.
    pub const tickets_per_machine = 2 + std.meta.fields(client.Job.Kind).len + 2;

    /// A window with one machine keeps the inbox's default, which also
    /// holds best-effort work such as system notices; each other machine
    /// adds what its client can hold, so sixteen busy machines leave that
    /// work the headroom it has beside one machine.
    pub const inbox_capacity = Inbox.default_capacity + (client.Machines.capacity - 1) * tickets_per_machine;
};

pub const Inbox = mailbox.GenericInbox(Message);
