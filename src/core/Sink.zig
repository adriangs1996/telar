const Sink = @This();
const source_namespace = @import("diagnostics.zig");
const std = @import("std");
file: if (source_namespace.enabled) ?source_namespace.File else void = if (source_namespace.enabled) null else {},

pub fn init(io: source_namespace.Io, endpoint: []const u8, suffix: []const u8) Sink {
    if (!source_namespace.enabled) {
        return .{};
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}.{s}.log", .{ endpoint, suffix }) catch
        return .{};
    const file = source_namespace.Io.Dir.createFileAbsolute(io, path, .{
        .exclusive = true,
        .permissions = source_namespace.File.Permissions.fromMode(0o600),
    }) catch return .{};
    return .{ .file = file };
}

pub fn deinit(sink: *Sink, io: source_namespace.Io) void {
    if (!source_namespace.enabled) {
        return;
    }
    if (sink.file) |file| {
        file.close(io);
    }
    sink.file = null;
}

pub fn available(sink: *const Sink) bool {
    return if (source_namespace.enabled) sink.file != null else false;
}

pub fn write(sink: *Sink, io: source_namespace.Io, bytes: []const u8) !void {
    if (!source_namespace.enabled or sink.file == null) {
        return;
    }
    try sink.file.?.writeStreamingAll(io, bytes);
}
