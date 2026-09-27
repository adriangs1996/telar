//! One client event through an adapter's inbox: a worker publishes a write
//! completion, the event loop receives it and hands it to its handler. The
//! event has the adapters' shape, the client's message beside small host
//! events, so its size follows `client.Message`.
const client = @import("telar-client");
const mailbox = @import("mailbox");
const std = @import("std");
const InboxContext = @This();

const Event = union(enum) {
    client: client.Message,
    draw: anyerror!void,
};

inbox: mailbox.GenericInbox(Event),
handled: u64 = 0,

/// Example: `var context = InboxContext.init(io); defer context.deinit();`
pub fn init(io: std.Io) InboxContext {
    return .{
        .inbox = .init(io, .{}),
    };
}

pub fn deinit(self: *InboxContext) void {
    self.inbox.deinit();
}

/// Publishes, receives and handles one write completion.
/// Example: `const handled = try context.roundTrip();`
pub fn roundTrip(self: *InboxContext) !u64 {
    const ticket = try self.inbox.reserve();
    _ = self.inbox.publish(
        ticket,
        .{
            .client = .{
                .sent = {},
            },
        },
    );
    self.handle(try self.inbox.receive());
    return self.handled;
}

/// Stands in for the adapter's dispatch, which takes the event by value.
noinline fn handle(self: *InboxContext, event: Event) void {
    var received = event;
    std.mem.doNotOptimizeAway(&received);
    self.handled +%= @intFromEnum(std.meta.activeTag(received));
}
