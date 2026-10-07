const std = @import("std");
const Collector = @import("Collector.zig");

/// Resolves file and directory roots into sorted, unique Zig source paths.
///
/// ```zig
/// const files = try collect(allocator, io, &.{"src"});
/// defer free(allocator, files);
/// ```
pub fn collect(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8) ![][]u8 {
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

pub fn shouldSkipDirectory(name: []const u8) bool {
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
