const diagnostics = @import("diagnostics.zig");
const std = @import("std");
const Sink = @This();

file: if (diagnostics.enabled) ?std.Io.File else void = if (diagnostics.enabled) null else {},

pub fn init(io: std.Io, endpoint: []const u8, suffix: []const u8) Sink {
    if (!diagnostics.enabled) {
        return .{};
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}.{s}.log", .{ endpoint, suffix }) catch
        return .{};
    const file = std.Io.Dir.createFileAbsolute(io, path, .{
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch return .{};
    return .{ .file = file };
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

pub fn write(self: *Sink, io: std.Io, bytes: []const u8) !void {
    if (!diagnostics.enabled or self.file == null) {
        return;
    }
    try self.file.?.writeStreamingAll(io, bytes);
}
