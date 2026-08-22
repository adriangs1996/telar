//! Development-only performance diagnostics.
//!
//! Release builds compile every call site away. Debug builds write JSON Lines
//! beside the runtime socket, never terminal or PTY contents.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const File = Io.File;

pub const enabled = builtin.mode == .Debug;
pub const interval_ns: u64 = std.time.ns_per_s;

pub const Timing = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,

    pub fn observe(timing: *Timing, elapsed_ns: u64) void {
        timing.count += 1;
        timing.total_ns +|= elapsed_ns;
        timing.max_ns = @max(timing.max_ns, elapsed_ns);
    }

    pub fn average(timing: Timing) u64 {
        return if (timing.count == 0) 0 else timing.total_ns / timing.count;
    }
};

pub const Sink = struct {
    file: if (enabled) ?File else void = if (enabled) null else {},

    pub fn init(io: Io, endpoint: []const u8, suffix: []const u8) Sink {
        if (!enabled) return .{};

        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}.{s}.log", .{ endpoint, suffix }) catch
            return .{};
        const file = Io.Dir.createFileAbsolute(io, path, .{
            .exclusive = true,
            .permissions = File.Permissions.fromMode(0o600),
        }) catch return .{};
        return .{ .file = file };
    }

    pub fn deinit(sink: *Sink, io: Io) void {
        if (!enabled) return;
        if (sink.file) |file| file.close(io);
        sink.file = null;
    }

    pub fn available(sink: *const Sink) bool {
        return if (enabled) sink.file != null else false;
    }

    pub fn write(sink: *Sink, io: Io, bytes: []const u8) !void {
        if (!enabled or sink.file == null) return;
        try sink.file.?.writeStreamingAll(io, bytes);
    }
};

pub fn now(io: Io) u64 {
    if (!enabled) return 0;
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

pub fn elapsed(start_ns: u64, end_ns: u64) u64 {
    return end_ns -| start_ns;
}

pub fn waitForTick(io: Io) anyerror!void {
    try io.sleep(.fromNanoseconds(interval_ns), .awake);
}

test "timings retain count, average, and worst sample" {
    var timing: Timing = .{};
    timing.observe(10);
    timing.observe(30);
    try std.testing.expectEqual(@as(u64, 2), timing.count);
    try std.testing.expectEqual(@as(u64, 20), timing.average());
    try std.testing.expectEqual(@as(u64, 30), timing.max_ns);
}
