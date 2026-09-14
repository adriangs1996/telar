//! The bounded outcome of one directory listing: the listed base, at most
//! `max_entries` child directories and whether the typed path itself exists.
const std = @import("std");
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const Entry = @import("PathCompletionEntry.zig");
const Result = @This();

pub const max_entries = 64;
pub const max_name_bytes = 255;
pub const max_path_bytes = max_cwd_bytes_module;

base: [max_path_bytes]u8 = undefined,
base_len: u16 = 0,
entries: [max_entries]Entry = undefined,
len: u8 = 0,
/// The expanded query names an existing directory.
exact_exists: bool = false,

pub fn baseSlice(result: *const Result) []const u8 {
    return result.base[0..result.base_len];
}

pub fn slice(result: *const Result) []const Entry {
    return result.entries[0..result.len];
}

/// Records the directory the entries belong to. Example: `result.setBase("/home/me");`
pub fn setBase(result: *Result, base: []const u8) !void {
    if (base.len > max_path_bytes) {
        return error.PathTooLong;
    }

    @memcpy(result.base[0..base.len], base);
    result.base_len = @intCast(base.len);
}

/// Appends one child directory name, keeping every joined path within
/// `max_path_bytes`. Example: `try result.append("telar");`
pub fn append(result: *Result, name: []const u8) !void {
    if (result.len == max_entries) {
        return error.TooManyEntries;
    }
    if (name.len == 0 or name.len > max_name_bytes or result.base_len + 1 + name.len > max_path_bytes) {
        return error.NameTooLong;
    }

    var entry: Entry = .{ .len = @intCast(name.len) };
    @memcpy(entry.name[0..name.len], name);
    result.entries[result.len] = entry;
    result.len += 1;
}

/// Joins the base and one entry into `buffer`; a base of "/" yields "/name".
/// Example: `const path = result.join(0, &buffer);`
pub fn join(result: *const Result, index: usize, buffer: *[max_path_bytes]u8) []const u8 {
    const base = result.baseSlice();
    const name = result.entries[index].slice();
    if (base.len == 1 and base[0] == '/') {
        buffer[0] = '/';
        @memcpy(buffer[1 .. 1 + name.len], name);
        return buffer[0 .. 1 + name.len];
    }

    @memcpy(buffer[0..base.len], base);
    buffer[base.len] = '/';
    @memcpy(buffer[base.len + 1 .. base.len + 1 + name.len], name);
    return buffer[0 .. base.len + 1 + name.len];
}

/// Orders entries by name so the same directory always lists the same way.
/// Example: `result.sort();`
pub fn sort(result: *Result) void {
    std.mem.sort(Entry, result.entries[0..result.len], {}, lessThan);
}

fn lessThan(_: void, left: Entry, right: Entry) bool {
    return std.mem.lessThan(u8, left.slice(), right.slice());
}

test "results bound entries and every joined path" {
    var result: Result = .{};
    try result.setBase("/");
    try result.append("b");
    try result.append("a");
    result.sort();
    var buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/a", result.join(0, &buffer));
    try std.testing.expectEqualStrings("/b", result.join(1, &buffer));

    try result.setBase("/home/me");
    try std.testing.expectEqualStrings("/home/me/a", result.join(0, &buffer));
    const long = [_]u8{'x'} ** (max_path_bytes - "/home/me".len);
    try std.testing.expectError(error.NameTooLong, result.append(&long));
    try std.testing.expectError(error.NameTooLong, result.append(""));

    var full: Result = .{};
    for (0..max_entries) |_| {
        try full.append("d");
    }
    try std.testing.expectError(error.TooManyEntries, full.append("e"));
}
