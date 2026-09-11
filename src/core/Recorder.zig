const std = @import("std");
const Record = @import("Record.zig");
const echo_trace = @import("echo_trace.zig");
const Recorder = @This();

const capacity = 16384;

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
        if (comptime echo_trace.cpu_enabled) {
            try writer.interface.print("{{\"ns\":{d},\"event\":\"{s}\",\"cpu_ns\":{d},\"thread\":{d}}}\n", .{ record.ns, @tagName(record.tag), record.cpu_ns, record.thread });
        } else {
            try writer.interface.print("{{\"ns\":{d},\"event\":\"{s}\"}}\n", .{ record.ns, @tagName(record.tag) });
        }
    }

    try writer.interface.print("{{\"dropped\":{d}}}\n", .{count -| capacity});
    try writer.interface.flush();
}
