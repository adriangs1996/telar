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
    @memset(buffer[0 .. limits.header_size + rows], 0);
    std.mem.writeInt(u16, buffer[1..3], rows, .little);
    return .{ .buffer = buffer, .len = limits.header_size + rows };
}

pub fn deinit(storage: *Storage, allocator: std.mem.Allocator) void {
    allocator.free(storage.buffer);
    storage.* = undefined;
}

/// Geometry changes reserve before applying any incoming cells.
/// Example: `try storage.reserve(allocator, rows);`
pub fn reserve(storage: *Storage, allocator: std.mem.Allocator, rows: u16) !void {
    if (storage.buffer.len >= limits.capacity(rows)) {
        return;
    }

    const replacement = try allocator.alloc(u8, limits.capacity(rows));
    @memcpy(replacement[0..storage.len], storage.buffer[0..storage.len]);
    allocator.free(storage.buffer);
    storage.buffer = replacement;
}

pub fn view(storage: *const Storage) View {
    return View.trusted(storage.buffer[0..storage.len]);
}

/// Copies a fully validated replacement into previously reserved storage.
/// Example: `storage.replace(view);`
pub fn replace(storage: *Storage, value: View) void {
    std.debug.assert(value.encoded.len <= storage.buffer.len);
    @memcpy(storage.buffer[0..value.encoded.len], value.encoded);
    storage.len = value.encoded.len;
}
