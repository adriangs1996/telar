const std = @import("std");
const Io = std.Io;

// The shared timeline event model.
//
// Both taps emit into this one type, and the main loop is the only ordering
// authority. That is the whole point of the merge: the PTY tap and the HTTPS
// proxy are two producers on one timeline, correlated by arrival order, not two
// logs to be stitched together afterwards.

pub const KB = 1 << 10;

/// An owned, bounded string. Nothing crossing the queue may borrow, because the
/// producer's buffer is gone by the time the main loop reads it.
pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *Self, text: []const u8) void {
            self.len = @min(text.len, capacity);
            @memcpy(self.bytes[0..self.len], text[0..self.len]);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const CommandLine = Text(512);
pub const Host = Text(256);

/// One read's worth of bytes. Fixed size so the queue is a bounded ring: a
/// runaway producer blocks instead of growing memory.
pub const Chunk = struct {
    bytes: [4 * KB]u8 = undefined,
    len: usize = 0,

    pub fn slice(chunk: *const Chunk) []const u8 {
        return chunk.bytes[0..chunk.len];
    }
};

pub const CommandFinished = struct {
    /// Null means the shell published no usable status.
    status: ?u8,
    /// Resolved text of what the command printed. Allocated by the producing
    /// actor and **owned by the receiver**, which must free it. Null when the
    /// command printed nothing worth keeping.
    output: ?[]const u8 = null,
    /// The command printed more than the capture budget allowed.
    truncated: bool = false,
};

pub const Upstream = struct {
    /// Pairs with the matching `upstream_closed`.
    id: u64,
    host: Host,
    port: u16,
};

/// One intercepted request/response pair, already readable.
pub const Exchange = struct {
    id: u64,
    host: Host,
    port: u16,
    request_bytes: u64,
    response_bytes: u64,
    duration_ms: i64,
    /// Redacted head plus captured bodies, ready to store. Allocated by the
    /// producing actor and **owned by the receiver**, which must free it.
    detail: ?[]const u8 = null,
    truncated: bool = false,
};

pub const UpstreamClose = struct {
    id: u64,
    bytes_up: u64,
    bytes_down: u64,
    duration_ms: i64,
};

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
