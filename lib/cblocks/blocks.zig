//! Each block carries its length in a header before the bytes the C library
//! sees, so `free` and `realloc` find the slice the Zig allocator handed out.
//! Blocks are aligned like `max_align_t`, which every C allocation hook
//! telar installs (SQLite, brotli, nghttp2) accepts.
const std = @import("std");

const block_alignment: std.mem.Alignment = .of(std.c.max_align_t);
const header_len = block_alignment.toByteUnits();

const Block = []align(block_alignment.toByteUnits()) u8;

/// A block of `bytes` usable bytes, or null when the allocator fails.
///
/// ```zig
/// const pointer = cblocks.alloc(gpa, 64) orelse return null;
/// defer cblocks.free(gpa, pointer);
/// ```
pub fn alloc(allocator: std.mem.Allocator, bytes: usize) ?*anyopaque {
    const total = std.math.add(usize, header_len, bytes) catch return null;
    const block = allocator.alignedAlloc(u8, block_alignment, total) catch return null;
    return seal(block);
}

/// `alloc` of `count * size` bytes set to zero, like `calloc`.
///
/// ```zig
/// const pointer = cblocks.zeroed(gpa, 4, 16) orelse return null;
/// ```
pub fn zeroed(allocator: std.mem.Allocator, count: usize, size: usize) ?*anyopaque {
    const bytes = std.math.mul(usize, count, size) catch return null;
    const pointer = alloc(allocator, bytes) orelse return null;
    const block: [*]u8 = @ptrCast(pointer);
    @memset(block[0..bytes], 0);
    return pointer;
}

/// Resizes a block like `realloc`: null `pointer` allocates, zero `bytes`
/// frees and returns null, and a failure leaves the old block intact.
///
/// ```zig
/// const grown = cblocks.realloc(gpa, pointer, 128) orelse return null;
/// ```
pub fn realloc(allocator: std.mem.Allocator, pointer: ?*anyopaque, bytes: usize) ?*anyopaque {
    const existing = pointer orelse return alloc(allocator, bytes);
    if (bytes == 0) {
        free(allocator, existing);
        return null;
    }

    const total = std.math.add(usize, header_len, bytes) catch return null;
    const block = allocator.realloc(unseal(existing), total) catch return null;
    return seal(block);
}

/// Returns a block to the allocator it came from; null is ignored.
///
/// ```zig
/// cblocks.free(gpa, pointer);
/// ```
pub fn free(allocator: std.mem.Allocator, pointer: ?*anyopaque) void {
    const existing = pointer orelse return;
    allocator.free(unseal(existing));
}

/// The usable bytes of a block.
///
/// ```zig
/// const bytes = cblocks.len(pointer);
/// ```
pub fn len(pointer: *anyopaque) usize {
    return unseal(pointer).len - header_len;
}

/// The usable bytes `alloc` rounds a request of `bytes` up to.
///
/// ```zig
/// const bytes = cblocks.roundUp(100);
/// ```
pub fn roundUp(bytes: usize) usize {
    return block_alignment.forward(bytes);
}

fn seal(block: Block) *anyopaque {
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], block.len, .little);
    return block[header_len..].ptr;
}

fn unseal(pointer: *anyopaque) Block {
    const bytes: [*]align(block_alignment.toByteUnits()) u8 = @ptrCast(@alignCast(pointer));
    const base = bytes - header_len;
    const total = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
    return base[0..total];
}

test "a block keeps its length through realloc and returns to its allocator" {
    const gpa = std.testing.allocator;
    const pointer = alloc(gpa, 10).?;
    try std.testing.expectEqual(@as(usize, 10), len(pointer));
    try std.testing.expect(block_alignment.check(@intFromPtr(pointer)));

    const bytes: [*]u8 = @ptrCast(pointer);
    @memcpy(bytes[0..10], "0123456789");
    const grown = realloc(gpa, pointer, 4000).?;
    try std.testing.expectEqual(@as(usize, 4000), len(grown));
    try std.testing.expectEqualStrings("0123456789", @as([*]u8, @ptrCast(grown))[0..10]);

    const shrunk = realloc(gpa, grown, 3).?;
    try std.testing.expectEqualStrings("012", @as([*]u8, @ptrCast(shrunk))[0..3]);
    try std.testing.expect(realloc(gpa, shrunk, 0) == null);
}

test "zeroed clears its bytes and refuses an overflowing size" {
    const gpa = std.testing.allocator;
    const pointer = zeroed(gpa, 8, 8).?;
    defer free(gpa, pointer);

    const bytes: [*]u8 = @ptrCast(pointer);
    for (bytes[0..64]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }

    try std.testing.expect(zeroed(gpa, std.math.maxInt(usize), 2) == null);
    try std.testing.expect(alloc(gpa, std.math.maxInt(usize)) == null);
}

test "a failed realloc leaves the block intact" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();
    const pointer = alloc(gpa, 8).?;
    defer free(gpa, pointer);

    try std.testing.expect(realloc(gpa, pointer, 1 << 20) == null);
    try std.testing.expectEqual(@as(usize, 8), len(pointer));
}
