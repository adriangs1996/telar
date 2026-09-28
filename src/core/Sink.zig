//! The diagnostics log of one process, `<endpoint>.<role>-<pid>.log` beside
//! the runtime socket. It is bounded: once a file holds `max_file_bytes` it
//! becomes `<name>.log.1`, replacing the previous one, and writing restarts
//! in an empty file, so a process keeps at most twice that on disk. The logs
//! of processes that ended are removed when a runtime or a client starts.
const builtin = @import("builtin");
const diagnostics = @import("diagnostics.zig");
const DiagnosticLogName = @import("DiagnosticLogName.zig");
const std = @import("std");
const Sink = @This();

/// Bytes a log holds before it rotates: about 17 minutes of runtime lines
/// or 8 of client lines, one a second.
pub const max_file_bytes = 4 * 1024 * 1024;
/// Suffix of the previous generation of a rotated log.
pub const rotated_suffix = DiagnosticLogName.rotated_suffix;
/// Most directory entries one cleanup looks at, so a crowded directory
/// cannot stall a start.
pub const max_scanned_entries = 4096;

file: if (diagnostics.enabled) ?std.Io.File else void = if (diagnostics.enabled) null else {},
path: if (diagnostics.enabled) [std.fs.max_path_bytes]u8 else void = undefined,
path_len: usize = 0,
written: u64 = 0,
limit: u64 = max_file_bytes,

pub fn init(io: std.Io, endpoint: []const u8, suffix: []const u8) Sink {
    if (!diagnostics.enabled) {
        return .{};
    }

    var sink: Sink = .{};
    const path = std.fmt.bufPrint(&sink.path, "{s}.{s}.log", .{ endpoint, suffix }) catch
        return .{};
    sink.path_len = path.len;
    sink.file = create(io, path) catch return .{};
    return sink;
}

pub fn deinit(self: *Sink, io: std.Io) void {
    if (!diagnostics.enabled) {
        return;
    }
    if (self.file) |file| {
        file.close(io);
    }
    self.file = null;
}

pub fn available(self: *const Sink) bool {
    return if (diagnostics.enabled) self.file != null else false;
}

/// Appends `bytes`, rotating the file first when they would take it past
/// its limit. A failed rotation fails the write, which retires the sink.
///
/// ```zig
/// try sink.write(io, line);
/// ```
pub fn write(self: *Sink, io: std.Io, bytes: []const u8) !void {
    if (!diagnostics.enabled or self.file == null) {
        return;
    }

    if (self.written != 0 and self.written + bytes.len > self.limit) {
        try self.rotate(io);
    }

    try self.file.?.writeStreamingAll(io, bytes);
    self.written += bytes.len;
}

fn rotate(self: *Sink, io: std.Io) !void {
    const path = self.path[0..self.path_len];
    if (path.len == 0) {
        return error.UnnamedSink;
    }

    var rotated_buffer: [std.fs.max_path_bytes + rotated_suffix.len]u8 = undefined;
    const rotated = try std.fmt.bufPrint(&rotated_buffer, "{s}{s}", .{ path, rotated_suffix });
    self.file.?.close(io);
    self.file = null;
    try std.Io.Dir.renameAbsolute(path, rotated, io);
    self.file = try create(io, path);
    self.written = 0;
}

fn create(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(io, path, .{
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
}

/// Removes, from the directory holding `endpoint`, the diagnostics logs of
/// every endpoint whose writing process no longer runs. Best effort: a log
/// that cannot be removed stays.
///
/// ```zig
/// Sink.removeOrphans(io, endpoint);
/// ```
pub fn removeOrphans(io: std.Io, endpoint: []const u8) void {
    if (comptime builtin.os.tag == .windows) {
        return;
    }

    const directory_path = std.fs.path.dirname(endpoint) orelse return;
    var directory = std.Io.Dir.openDirAbsolute(io, directory_path, .{ .iterate = true }) catch return;
    defer directory.close(io);

    var entries = directory.iterate();
    var scanned: usize = 0;
    while (scanned < max_scanned_entries) : (scanned += 1) {
        const entry = (entries.next(io) catch return) orelse return;
        if (entry.kind != .file) {
            continue;
        }

        const log = DiagnosticLogName.parse(entry.name) orelse continue;
        if (running(log.pid)) {
            continue;
        }

        directory.deleteFile(io, entry.name) catch {};
    }
}

/// Whether a process with this id exists; one of another user counts.
fn running(pid: u32) bool {
    const id = std.math.cast(std.c.pid_t, pid) orelse return false;
    // Signal 0 only checks that the process exists.
    const result = std.c.kill(id, @enumFromInt(0));
    return result == 0 or std.posix.errno(result) != .SRCH;
}

test "a full log rotates into one previous generation" {
    if (!diagnostics.enabled) {
        return error.SkipZigTest;
    }

    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/t.sock", .{directory});

    var sink = Sink.init(io, endpoint, "runtime-5");
    defer sink.deinit(io);
    sink.limit = 10;
    try sink.write(io, "aaaa\n");
    try sink.write(io, "bbbb\n");
    try sink.write(io, "cccc\n");
    try sink.write(io, "dddd\n");
    try sink.write(io, "eeee\n");

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("eeee\n", try temp.dir.readFile(io, "t.sock.runtime-5.log", &buffer));
    try std.testing.expectEqualStrings("cccc\ndddd\n", try temp.dir.readFile(io, "t.sock.runtime-5.log.1", &buffer));
}

test "cleanup removes the logs of processes that ended and keeps the rest" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/runtime.sock", .{directory});

    // No system hands out a pid this high: macOS stops at 99998, Linux at 2^22.
    const gone = "other.sock.runtime-4194305.log";
    const gone_rotated = "runtime.sock.client-4194305.log.1";
    var own_buffer: [64]u8 = undefined;
    const own = try std.fmt.bufPrint(&own_buffer, "runtime.sock.client-{d}.log", .{std.c.getpid()});
    for ([_][]const u8{ gone, gone_rotated, own, "notes.log" }) |name| {
        try temp.dir.writeFile(io, .{ .sub_path = name, .data = "{}\n" });
    }

    removeOrphans(io, endpoint);

    for ([_][]const u8{ gone, gone_rotated }) |name| {
        try std.testing.expectError(error.FileNotFound, temp.dir.statFile(io, name, .{}));
    }
    for ([_][]const u8{ own, "notes.log" }) |name| {
        _ = try temp.dir.statFile(io, name, .{});
    }
}
