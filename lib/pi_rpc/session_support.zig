//! One engine child and the dialogue that turns a prompt into its reply.
//!
//! A session spawns the command on `open`, keeps its pipes for as long as
//! the actor reuses it, and is killed on `close`. `ask` speaks the Pi RPC
//! dialogue: send the prompt, wait for the agent to settle, then query the
//! last assistant text. Every failure surfaces as a `Status`; what happens
//! to the child afterwards is the actor's decision, never the session's.

const std = @import("std");

pub const AskError = error{ Timeout, ReadFailed, Closed, Rejected, InvalidOutput, WriteFailed };

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}
