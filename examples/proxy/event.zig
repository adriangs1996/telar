const std = @import("std");
const Io = std.Io;

// The shared timeline event model.
//
// Both taps emit into this one type, and the main loop is the only ordering
// authority. That is the whole point of the merge: the PTY tap and the HTTPS
// proxy are two producers on one timeline, correlated by arrival order, not two
// logs to be stitched together afterwards.

pub const KB = 1 << 10;

pub const Text = @import("GenericText.zig").Type;

pub const CommandLine = Text(512);
pub const Host = Text(256);

pub const Chunk = @import("Chunk.zig");

pub const CommandFinished = @import("CommandFinished.zig");

pub const Upstream = @import("Upstream.zig");

pub const Exchange = @import("Exchange.zig");

pub const UpstreamClose = @import("UpstreamClose.zig");

pub const Event = union(enum) {
    /// Bytes the user typed, still unparsed.
    user_input: Chunk,
    /// OSC 133;C — a command started running.
    command_started: CommandLine,
    /// OSC 133;D — it finished.
    command_finished: CommandFinished,
    /// The child opened a tunnel through the proxy.
    upstream_opened: Upstream,
    /// That tunnel closed.
    upstream_closed: UpstreamClose,
    /// A request and its response, seen in the clear.
    upstream_exchange: Exchange,
    /// The host terminal changed size.
    resized,
    /// The pty master reached end of stream, so the child is gone.
    child_gone,
};

pub const Queue = Io.Queue(Event);
