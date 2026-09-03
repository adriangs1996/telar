const std = @import("std");

const Io = std.Io;

const Collector = struct {
    allocator: std.mem.Allocator,
    io: Io,
    files: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Collector) void {
        for (self.files.items) |path| {
            self.allocator.free(path);
        }

        self.files.deinit(self.allocator);
    }

    fn addRoot(self: *Collector, path: []const u8) !void {
        const stat = try Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false });

        switch (stat.kind) {
            .directory => try self.addDirectory(path),
            .file => {
                if (std.mem.endsWith(u8, path, ".zig")) {
                    try self.files.append(self.allocator, try self.allocator.dupe(u8, path));
                }
            },
            else => {},
        }
    }

    fn addDirectory(self: *Collector, path: []const u8) !void {
        var directory = try Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer directory.close(self.io);

        var walker = try directory.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(self.io)) |entry| {
            if (entry.kind == .directory and shouldSkipDirectory(entry.basename)) {
                walker.leave(self.io);
                continue;
            }

            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) {
                continue;
            }

            const file_path = try std.fs.path.join(self.allocator, &.{ path, entry.path });
            errdefer self.allocator.free(file_path);
            try self.files.append(self.allocator, file_path);
        }
    }
};

/// Resolves file and directory roots into sorted, unique Zig source paths.
///
/// ```zig
/// const files = try collect(allocator, io, &.{"src"});
/// defer free(allocator, files);
/// ```
pub fn collect(allocator: std.mem.Allocator, io: Io, roots: []const []const u8) ![][]u8 {
    var collector: Collector = .{ .allocator = allocator, .io = io };
    errdefer collector.deinit();

    for (roots) |root| {
        try collector.addRoot(root);
    }

    std.sort.insertion([]u8, collector.files.items, {}, pathBefore);
    removeDuplicates(allocator, &collector.files);
    return collector.files.toOwnedSlice(allocator);
}

/// Releases paths returned by `collect`.
///
/// ```zig
/// free(allocator, files);
/// ```
pub fn free(allocator: std.mem.Allocator, files: []const []u8) void {
    for (files) |path| {
        allocator.free(path);
    }

    allocator.free(files);
}

fn removeDuplicates(allocator: std.mem.Allocator, files: *std.ArrayList([]u8)) void {
    if (files.items.len < 2) {
        return;
    }

    var write_index: usize = 1;
    for (files.items[1..]) |path| {
        if (std.mem.eql(u8, files.items[write_index - 1], path)) {
            allocator.free(path);
            continue;
        }

        files.items[write_index] = path;
        write_index += 1;
    }

    files.items.len = write_index;
}

fn pathBefore(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn shouldSkipDirectory(name: []const u8) bool {
    const ignored = [_][]const u8{
        ".git",
        ".zig-cache",
        "zig-cache",
        "zig-out",
        "zig-pkg",
        "vendor",
    };

    for (ignored) |candidate| {
        if (std.mem.eql(u8, name, candidate)) {
            return true;
        }
    }

    return false;
}

test "collects sorted unique Zig files and skips generated directories" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.createDirPath(io, "nested");
    try temp.dir.createDirPath(io, ".zig-cache");
    try temp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn a() void {}\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignored\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "nested/b.zig", .data = "fn b() void {}\n" });
    try temp.dir.writeFile(io, .{ .sub_path = ".zig-cache/generated.zig", .data = "fn generated() void {}\n" });

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buffer, "{s}/a.zig", .{directory});

    const files = try collect(std.testing.allocator, io, &.{ directory, file });
    defer free(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(std.mem.endsWith(u8, files[0], "/a.zig"));
    try std.testing.expect(std.mem.endsWith(u8, files[1], "/nested/b.zig"));
}
