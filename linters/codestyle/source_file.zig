const std = @import("std");

pub const Io = std.Io;
pub const max_source_bytes = 16 * 1024 * 1024;

pub const SourceFile = @import("SourceFile.zig");

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
