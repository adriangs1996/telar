const core = @import("telar-core");
const std = @import("std");
const ReviewFileSample = @This();

pub const capacity = core.change_review.max_sample_bytes;

storage: [capacity + 1]u8 = undefined,
len: usize = 0,
exists: bool = false,

/// Samples one bounded regular text file; every path component rejects symlinks.
/// Example: `try sample.read(io, "/workspace/src/main.zig");`
pub fn read(self: *ReviewFileSample, io: std.Io, path: []const u8) !void {
    self.len = 0;
    self.exists = false;
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidReviewPath;
    }

    var directory = try std.Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false });
    defer directory.close(io);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    var part = parts.next() orelse return error.InvalidReviewPath;
    while (parts.next()) |next| {
        if (std.mem.eql(u8, part, "..")) {
            return error.InvalidReviewPath;
        }

        const child = directory.openDir(io, part, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.UnsafeReviewFile,
        };
        directory.close(io);
        directory = child;
        part = next;
    }

    if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) {
        return error.InvalidReviewPath;
    }

    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buffer, "{s}", .{part});
    const fd = std.c.openat(directory.handle, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) {
        if (std.posix.errno(fd) == .NOENT) {
            return;
        }

        return error.UnsafeReviewFile;
    }

    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file or before.size > capacity) {
        return error.UnsafeReviewFile;
    }

    var reader = file.readerStreaming(io, &.{});
    self.len = try reader.interface.readSliceShort(&self.storage);
    const after = try file.stat(io);
    if (self.len > capacity or self.len != before.size or before.size != after.size or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime)) {
        return error.UnstableReviewFile;
    }

    const content = self.storage[0..self.len];
    if (!std.unicode.utf8ValidateSlice(content)) {
        return error.BinaryReviewFile;
    }

    for (content) |byte| {
        if ((byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') or byte == 0x7f) {
            return error.BinaryReviewFile;
        }
    }

    self.exists = true;
}

test "review file samples distinguish absent empty and text and reject unsafe paths" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "source.zig", .data = "const label = \"café 界\";\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try temp.dir.writeFile(io, .{ .sub_path = "binary", .data = "binary\x00data" });
    try temp.dir.writeFile(io, .{ .sub_path = "oversized", .data = "x" ** (capacity + 1) });
    try temp.dir.symLink(io, "source.zig", "link", .{});
    try temp.dir.symLink(io, ".", "linked-directory", .{ .is_directory = true });
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var sample: ReviewFileSample = .{};
    try sample.read(io, try std.fmt.bufPrint(&path_buffer, "{s}/source.zig", .{directory}));
    try std.testing.expect(sample.exists);
    try std.testing.expectEqualStrings("const label = \"café 界\";\n", sample.storage[0..sample.len]);
    try sample.read(io, try std.fmt.bufPrint(&path_buffer, "{s}/missing", .{directory}));
    try std.testing.expect(!sample.exists);
    try sample.read(io, try std.fmt.bufPrint(&path_buffer, "{s}/empty", .{directory}));
    try std.testing.expect(sample.exists and sample.len == 0);
    try std.testing.expectError(error.BinaryReviewFile, sample.read(io, try std.fmt.bufPrint(&path_buffer, "{s}/binary", .{directory})));
    try std.testing.expectError(error.UnsafeReviewFile, sample.read(io, try std.fmt.bufPrint(&path_buffer, "{s}/oversized", .{directory})));
    for ([_][]const u8{ "link", "linked-directory/source.zig" }) |leaf| {
        try std.testing.expectError(error.UnsafeReviewFile, sample.read(io, try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, leaf })));
    }
}
