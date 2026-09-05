//! Opt-in fixed-capacity traces. The process bootstrap owns the recorder.
const std = @import("std");
const root = @import("root");

pub const enabled = @hasDecl(root, "telar_echo_trace") and root.telar_echo_trace;
pub const Tag = enum {
    host_read,
    client_input,
    client_send_start,
    client_send_done,
    runtime_read,
    runtime_dispatch,
    input_forward,
    foreground_start,
    foreground_done,
    input_observed,
    pty_write_queued,
    pty_write_start,
    pty_write_done,
    pty_read,
    output_dispatch,
    vt_queued,
    vt_start,
    vt_done,
    ingest_dispatch,
    runtime_send_start,
    runtime_send_done,
    client_read,
    client_frame,
    compose_start,
    host_flush_start,
    host_flush_done,
};

pub const Recorder = struct {
    const capacity = 16384;
    const Record = struct { ns: u64, tag: Tag };
    claimed: std.atomic.Value(usize) = .init(0),
    records: [capacity]Record = undefined,

    /// Claims a unique slot. No allocation, lock or I/O; full traces drop work.
    /// Example: `recorder.append(.{ .ns = now, .tag = .pty_read });`.
    pub fn append(recorder: *Recorder, record: Record) void {
        const index = recorder.claimed.fetchAdd(1, .monotonic);
        if (index < capacity) {
            recorder.records[index] = record;
        }
    }

    /// Writes only after every producer has joined. Never call during a borrow.
    /// Example: `try recorder.dump(io, directory);`.
    pub fn dump(recorder: *const Recorder, io: std.Io, directory: []const u8) !void {
        const count = recorder.claimed.load(.monotonic);
        if (count == 0) {
            return;
        }
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{d}.echo.jsonl", .{ directory, std.c.getpid() });
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        for (recorder.records[0..@min(count, capacity)]) |record| {
            try writer.interface.print("{{\"ns\":{d},\"event\":\"{s}\"}}\n", .{ record.ns, @tagName(record.tag) });
        }
        try writer.interface.print("{{\"dropped\":{d}}}\n", .{count -| capacity});
        try writer.interface.flush();
    }
};

/// Compiles away without `-Decho-trace`; records no contents, pane or request IDs.
/// Example: `echo_trace.mark(io, .pty_read);`.
pub fn mark(io: std.Io, tag: Tag) void {
    if (comptime enabled) {
        root.echo_recorder.append(.{ .ns = @intCast(std.Io.Clock.awake.now(io).nanoseconds), .tag = tag });
    }
}

test "trace saturation does not overwrite retained records" {
    const recorder = try std.testing.allocator.create(Recorder);
    defer std.testing.allocator.destroy(recorder);
    recorder.* = .{};
    for (0..Recorder.capacity + 10) |index| {
        recorder.append(.{ .ns = index, .tag = .host_read });
    }
    try std.testing.expectEqual(@as(u64, 0), recorder.records[0].ns);
    try std.testing.expectEqual(@as(u64, Recorder.capacity - 1), recorder.records[Recorder.capacity - 1].ns);
}
