const InitOptionsType = @import("InitOptions.zig");
const std = @import("std");
const Record = @import("Record.zig");
const rpc = @import("rpc.zig");
/// One LF-framed record stream over a child's stdout. Unparseable lines are
/// skipped and lines above `max_line_bytes` are discarded whole, so a noisy
/// or hostile child never stalls the reader or grows its buffer. The stream
/// must live at a stable address from `init` to `deinit`.
const Stream = @This();

streams: std.Io.File.MultiReader.Buffer(1) = undefined,
reader: std.Io.File.MultiReader = undefined,
discarding: bool = false,

pub const Next = union(enum) {
    record: Record,
    /// A record above the line bound was dropped whole.
    discarded,
    /// The child closed its output.
    closed,
};

pub const Error = error{ Timeout, ReadFailed };

pub const InitOptions = @import("InitOptions.zig");

/// Follows `stdout` until `deinit`.
///
/// ```zig
/// session.stream.init(.{ .allocator = gpa, .io = io, .stdout = child.stdout.? });
/// defer session.stream.deinit();
/// ```
pub fn init(stream: *Stream, options: InitOptionsType) void {
    stream.discarding = false;
    stream.reader.init(options.allocator, options.io, stream.streams.toStreams(), &.{options.stdout});
}

pub fn deinit(stream: *Stream) void {
    stream.reader.deinit();
}

/// Yields the next parseable record. Waits at most until `timeout`.
///
/// ```zig
/// var step = try stream.next(gpa, timeout);
/// switch (step) {
///     .record => |*record| defer record.deinit(),
///     .discarded, .closed => {},
/// }
/// ```
pub fn next(stream: *Stream, gpa: std.mem.Allocator, timeout: std.Io.Timeout) Error!Next {
    const reader = stream.reader.reader(0);

    while (true) {
        const buffered = reader.buffered();
        if (std.mem.indexOfScalar(u8, buffered, '\n')) |newline| {
            var line = buffered[0..newline];
            if (line.len != 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            const was_discarding = stream.discarding;
            stream.discarding = false;
            if (was_discarding) {
                reader.toss(newline + 1);
                return .discarded;
            }

            const record = rpc.parse(gpa, line);
            reader.toss(newline + 1);
            if (record) |value| {
                return .{ .record = value };
            }

            continue;
        }

        if (buffered.len > rpc.max_line_bytes) {
            reader.toss(buffered.len);
            stream.discarding = true;
        }

        stream.reader.fill(1, timeout) catch |err| switch (err) {
            error.EndOfStream => return .closed,
            error.Timeout => return error.Timeout,
            else => return error.ReadFailed,
        };
    }
}
