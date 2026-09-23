//! Owned, bounded bytes; frames replace their contents without allocating.
const std = @import("std");
const limits = @import("limits.zig");
const View = @import("View.zig");
const Storage = @This();

buffer: []u8,
len: usize,

/// Reserves all URI/run capacity and the initial row flags.
/// Example: `var storage = try Storage.init(gpa, rows);`
pub fn init(allocator: std.mem.Allocator, rows: u16) !Storage {
    const buffer = try allocator.alloc(u8, limits.capacity(rows));
    @memset(buffer[0 .. limits.header_size + @as(usize, rows)], 0);
    std.mem.writeInt(u16, buffer[1..3], rows, .little);
    return .{ .buffer = buffer, .len = limits.header_size + @as(usize, rows) };
}

pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
    allocator.free(self.buffer);
    self.* = undefined;
}

/// Geometry changes reserve before applying any incoming cells.
/// Example: `try storage.reserve(allocator, rows);`
pub fn reserve(self: *Storage, allocator: std.mem.Allocator, rows: u16) !void {
    if (self.buffer.len >= limits.capacity(rows)) {
        return;
    }

    const replacement = try allocator.alloc(u8, limits.capacity(rows));
    @memcpy(replacement[0..self.len], self.buffer[0..self.len]);
    allocator.free(self.buffer);
    self.buffer = replacement;
}

pub fn view(self: *const Storage) View {
    return View.trusted(self.buffer[0..self.len]);
}

/// Copies a fully validated replacement into previously reserved storage.
/// Example: `storage.replace(view);`
pub fn replace(self: *Storage, value: View) void {
    std.debug.assert(value.encoded.len <= self.buffer.len);
    @memcpy(self.buffer[0..value.encoded.len], value.encoded);
    self.len = value.encoded.len;
}
