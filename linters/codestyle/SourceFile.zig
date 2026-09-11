const SourceFile = @This();
const std = @import("std");
const source_namespace = @import("source_file.zig");
allocator: std.mem.Allocator,
path: []const u8,
permissions: source_namespace.Io.File.Permissions,
source: [:0]u8,

/// Opens one regular Zig source file and retains its permissions for replacement.
///
/// ```zig
/// var file = try SourceFile.open(allocator, io, "src/main.zig");
/// defer file.deinit();
/// ```
pub fn open(allocator: std.mem.Allocator, io: source_namespace.Io, path: []const u8) !SourceFile {
    const directory = source_namespace.Io.Dir.cwd();
    const stat = try directory.statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file) {
        return error.NotAFile;
    }

    return .{
        .allocator = allocator,
        .path = path,
        .permissions = stat.permissions,
        .source = try directory.readFileAllocOptions(io, path, allocator, .limited(source_namespace.max_source_bytes), .of(u8), 0),
    };
}

/// Releases the source buffer owned by this file.
///
/// ```zig
/// file.deinit();
/// ```
pub fn deinit(self: *SourceFile) void {
    self.allocator.free(self.source);
    self.* = undefined;
}

/// Atomically replaces the file while preserving its original permissions.
///
/// ```zig
/// try file.replace(io, fixed_source);
/// ```
pub fn replace(self: SourceFile, io: source_namespace.Io, source: []const u8) !void {
    var atomic_file = try source_namespace.Io.Dir.cwd().createFileAtomic(io, self.path, .{
        .permissions = self.permissions,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    try file_writer.interface.writeAll(source);
    try file_writer.flush();
    try atomic_file.replace(io);
}
