//! Standard output and error of one child, collected until both close or
//! the deadline passes. A stream bound by `fail_past` stops the read with
//! `error.StreamTooLong`, for output a caller parses whole; `keep_head`
//! keeps its first bytes, for records a caller can use in part; `keep_tail`
//! keeps its last bytes, for diagnostics where the end says what went
//! wrong. Every dropped byte is counted.
const std = @import("std");
const Bound = @import("Bound.zig").Bound;
const Bounds = @import("Bounds.zig");
const KeptStream = @import("KeptStream.zig");
const ChildOutput = @This();

/// Bytes each read asks room for.
const read_chunk = 4096;

term: std.process.Child.Term,
stdout: KeptStream,
stderr: KeptStream,

/// Reads the child's piped stdout and stderr within `bounds`, then waits
/// for it. `bounds.timeout` is one deadline for the whole read, not a
/// silence allowed between reads. The caller keeps `defer child.kill(io)`,
/// which stops a child the read gave up on and does nothing once it was
/// waited for.
///
/// ```zig
/// var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
/// defer child.kill(io);
/// const output = try ChildOutput.collect(gpa, io, &child, .{ .stdout = .{ .fail_past = 4096 }, .stderr = .{ .keep_tail = 4096 } });
/// defer output.deinit(gpa);
/// ```
pub fn collect(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child, bounds: Bounds) !ChildOutput {
    // SAFETY: toStreams sets the count; MultiReader.init fills the contexts and initializes the operation batch before use.
    var streams_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    // SAFETY: MultiReader.init assigns streams in place before any read or deferred deinit.
    var streams: std.Io.File.MultiReader = undefined;
    streams.init(
        gpa,
        io,
        streams_buffer.toStreams(),
        &.{
            child.stdout.?,
            child.stderr.?,
        },
    );
    defer streams.deinit();

    const deadline = bounds.timeout.toDeadline(io);
    var kept: [2]Kept = .{
        .{
            .bound = bounds.stdout,
        },
        .{
            .bound = bounds.stderr,
        },
    };
    defer kept[0].head.deinit(gpa);
    defer kept[1].head.deinit(gpa);

    while (streams.fill(read_chunk, deadline)) |_| {
        for (&kept, 0..) |*stream, index| {
            try stream.observe(gpa, streams.reader(index));
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }

    try streams.checkAnyError();
    const term = try child.wait(io);

    const stdout = try kept[0].finish(gpa, &streams, 0);
    errdefer gpa.free(stdout.bytes);

    const stderr = try kept[1].finish(gpa, &streams, 1);
    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
    };
}

pub fn deinit(self: ChildOutput, gpa: std.mem.Allocator) void {
    gpa.free(self.stdout.bytes);
    gpa.free(self.stderr.bytes);
}

/// Whether the child exited on its own with status zero.
///
/// ```zig
/// if (!output.succeeded()) return error.GitFailed;
/// ```
pub fn succeeded(self: ChildOutput) bool {
    return self.term == .exited and self.term.exited == 0;
}

/// One stream while it is read: its bound, what it kept and counted, and
/// the head a `keep_head` bound copies out of the reader.
const Kept = struct {
    bound: Bound,
    stream: KeptStream = .{},
    /// Bytes of the reader's buffer already counted.
    seen: usize = 0,
    head: std.ArrayList(u8) = .empty,

    // Counts the lines a read added and applies the stream's bound.
    fn observe(self: *Kept, gpa: std.mem.Allocator, reader: *std.Io.Reader) !void {
        const buffered = reader.buffered();
        self.stream.lines += std.mem.count(u8, buffered[self.seen..], "\n");

        switch (self.bound) {
            .fail_past => |limit| {
                if (buffered.len > limit) {
                    return error.StreamTooLong;
                }
            },
            .keep_head => |limit| {
                const room = limit - self.head.items.len;
                const taken = @min(room, buffered.len);
                try self.head.appendSlice(gpa, buffered[0..taken]);
                self.stream.dropped += buffered.len - taken;
                reader.toss(buffered.len);
            },
            .keep_tail => |limit| {
                if (buffered.len > limit) {
                    const excess = buffered.len - limit;
                    reader.toss(excess);
                    self.stream.dropped += excess;
                }
            },
        }

        self.seen = reader.bufferedLen();
    }

    // Hands the kept bytes to the caller, who frees them.
    fn finish(self: *Kept, gpa: std.mem.Allocator, streams: *std.Io.File.MultiReader, index: usize) !KeptStream {
        var stream = self.stream;
        stream.bytes = switch (self.bound) {
            .keep_head => try self.head.toOwnedSlice(gpa),
            .fail_past, .keep_tail => try streams.toOwnedSlice(index),
        };

        return stream;
    }
};
