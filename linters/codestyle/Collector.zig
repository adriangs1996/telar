const std = @import("std");
const paths = @import("paths.zig");
const Collector = @This();

allocator: std.mem.Allocator,
io: std.Io,
files: std.ArrayList([]u8) = .empty,

pub fn deinit(self: *Collector) void {
    for (self.files.items) |path| {
        self.allocator.free(path);
    }

    self.files.deinit(self.allocator);
}

pub fn addRoot(self: *Collector, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false });

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
    var directory = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
    defer directory.close(self.io);

    var walker = try directory.walk(self.allocator);
    defer walker.deinit();

    while (try walker.next(self.io)) |entry| {
        if (entry.kind == .directory and paths.shouldSkipDirectory(entry.basename)) {
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
