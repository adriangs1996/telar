const std = @import("std");

const Io = std.Io;
const max_source_bytes = 16 * 1024 * 1024;

pub const SourceFile = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    permissions: Io.File.Permissions,
    source: [:0]u8,

    /// Opens one regular Zig source file and retains its permissions for replacement.
    ///
    /// ```zig
    /// var file = try SourceFile.open(allocator, io, "src/main.zig");
    /// defer file.deinit();
    /// ```
    pub fn open(allocator: std.mem.Allocator, io: Io, path: []const u8) !SourceFile {
        const directory = Io.Dir.cwd();
        const stat = try directory.statFile(io, path, .{ .follow_symlinks = false });
        if (stat.kind != .file) {
            return error.NotAFile;
        }

        return .{
            .allocator = allocator,
            .path = path,
            .permissions = stat.permissions,
            .source = try directory.readFileAllocOptions(io, path, allocator, .limited(max_source_bytes), .of(u8), 0),
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
    pub fn replace(self: SourceFile, io: Io, source: []const u8) !void {
        var atomic_file = try Io.Dir.cwd().createFileAtomic(io, self.path, .{
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
};

test "atomically replaces contents and preserves permissions" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.writeFile(io, .{
        .sub_path = "source.zig",
        .data = "fn before() void {}\n",
        .flags = .{ .permissions = Io.File.Permissions.fromMode(0o640) },
    });

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/source.zig", .{directory_buffer[0..directory_len]});

    var file = try SourceFile.open(std.testing.allocator, io, path);
    defer file.deinit();
    try std.testing.expectEqualStrings("fn before() void {}\n", file.source);
    try file.replace(io, "fn after() void {}\n");

    const written = try Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(max_source_bytes));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("fn after() void {}\n", written);

    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o640), stat.permissions.toMode() & 0o777);
}
