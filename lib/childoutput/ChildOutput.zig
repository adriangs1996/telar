//! Standard output and error of one child, collected until both close. A
//! stream bound by `fail_past` stops the read with `error.StreamTooLong`,
//! for output a caller parses whole; one bound by `keep_tail` keeps its last
//! bytes, for diagnostics where the end says what went wrong.
const std = @import("std");
const ChildOutput = @This();

/// Bytes each read asks room for.
const read_chunk = 4096;

pub const Bound = @import("Bound.zig").Bound;
pub const Bounds = @import("Bounds.zig");
pub const Stream = @import("KeptStream.zig");

term: std.process.Child.Term,
stdout: Stream,
stderr: Stream,

/// Reads the child's piped stdout and stderr within `bounds`, then waits
/// for it. The caller keeps `defer child.kill(io)`, which stops a child the
/// read gave up on and does nothing once it was waited for.
///
/// ```zig
/// var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
/// defer child.kill(io);
/// const output = try ChildOutput.collect(gpa, io, &child, .{ .stdout = .{ .fail_past = 4096 }, .stderr = .{ .keep_tail = 4096 } });
/// defer output.deinit(gpa);
/// ```
pub fn collect(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child, bounds: Bounds) !ChildOutput {
    var streams_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var streams: std.Io.File.MultiReader = undefined;
    streams.init(gpa, io, streams_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer streams.deinit();

    const limits = [2]Bound{ bounds.stdout, bounds.stderr };
    var kept: [2]Stream = .{ .{}, .{} };
    var seen: [2]usize = .{ 0, 0 };
    while (streams.fill(read_chunk, bounds.timeout)) |_| {
        for (limits, &kept, &seen, 0..) |limit, *stream, *observed, index| {
            try observe(streams.reader(index), limit, stream, observed);
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }

    try streams.checkAnyError();
    const term = try child.wait(io);

    kept[0].bytes = try streams.toOwnedSlice(0);
    errdefer gpa.free(kept[0].bytes);

    kept[1].bytes = try streams.toOwnedSlice(1);
    return .{
        .term = term,
        .stdout = kept[0],
        .stderr = kept[1],
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

// Counts the lines a read added and applies the stream's bound.
fn observe(reader: *std.Io.Reader, bound: Bound, stream: *Stream, seen: *usize) !void {
    const buffered = reader.buffered();
    stream.lines += std.mem.count(u8, buffered[seen.*..], "\n");

    switch (bound) {
        .fail_past => |limit| {
            if (buffered.len > limit) {
                return error.StreamTooLong;
            }
        },
        .keep_tail => |limit| {
            if (buffered.len > limit) {
                const excess = buffered.len - limit;
                reader.toss(excess);
                stream.dropped += excess;
            }
        },
    }

    seen.* = reader.bufferedLen();
}

fn spawnShell(io: std.Io, script: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

test "a stream kept by its tail holds its newest bytes and counts the rest" {
    const io = std.testing.io;
    var child = try spawnShell(io, "i=0; while [ $i -lt 2000 ]; do echo line-$i >&2; i=$((i+1)); done; echo done");
    defer child.kill(io);

    const output = try collect(
        std.testing.allocator,
        io,
        &child,
        .{
            .stdout = .{ .fail_past = 64 },
            .stderr = .{ .keep_tail = 32 },
        },
    );
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.succeeded());
    try std.testing.expectEqualStrings("done\n", output.stdout.bytes);
    try std.testing.expect(output.stderr.bytes.len <= 32);
    try std.testing.expect(std.mem.endsWith(u8, output.stderr.bytes, "line-1999\n"));
    try std.testing.expectEqual(@as(u64, 2000), output.stderr.lines);
    try std.testing.expect(output.stderr.dropped + output.stderr.bytes.len > 2000 * "line-0\n".len);
}

test "a stream past its fail bound fails the read" {
    const io = std.testing.io;
    var child = try spawnShell(io, "i=0; while [ $i -lt 100 ]; do echo 0123456789; i=$((i+1)); done");
    defer child.kill(io);

    try std.testing.expectError(error.StreamTooLong, collect(
        std.testing.allocator,
        io,
        &child,
        .{
            .stdout = .{ .fail_past = 100 },
            .stderr = .{ .keep_tail = 0 },
        },
    ));
}

test "a tail of zero bytes only counts lines" {
    const io = std.testing.io;
    var child = try spawnShell(io, "printf 'a\\nb\\nc\\n'; exit 3");
    defer child.kill(io);

    const output = try collect(
        std.testing.allocator,
        io,
        &child,
        .{
            .stdout = .{ .keep_tail = 0 },
            .stderr = .{ .keep_tail = 0 },
        },
    );
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(!output.succeeded());
    try std.testing.expectEqual(@as(u64, 3), output.stdout.lines);
    try std.testing.expectEqual(@as(usize, 0), output.stdout.bytes.len);
    try std.testing.expectEqual(@as(u64, 6), output.stdout.dropped);
}
