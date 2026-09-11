//! Borrowed receive handle for one consumer. The owner retains queue lifecycle.

pub const InboxReceiver = @import("GenericInboxReceiver.zig").Type;
