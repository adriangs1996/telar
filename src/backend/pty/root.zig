//! Public child-process and pseudo-terminal capability.
//!
//! Callers describe one borrowed command and obtain a `Session` only after
//! the child has successfully replaced its process image. The session owns
//! both the child lifecycle and the PTY master until `deinit`.

const command = @import("command.zig");
const environment = @import("environment.zig");
const exit = @import("exit.zig");
const session = @import("session.zig");

pub const max_args = command.max_args;
pub const Command = command.Command;
pub const Environment = environment.Environment;
pub const Exit = exit.Exit;
pub const Size = session.Size;
pub const Session = session.Session;

test {
    @import("std").testing.refAllDecls(@This());
}
