const std = @import("std");
const Buffer = @This();

gpa: std.mem.Allocator,
storage: []u8 = &.{},
len: usize = 0,
max_bytes: usize,
truncated: bool = false,

pub fn init(gpa: std.mem.Allocator, max_bytes: usize) Buffer {
    return .{ .gpa = gpa, .max_bytes = max_bytes };
}

pub fn append(buffer: *Buffer, input: []const u8) bool {
    const available = buffer.max_bytes -| buffer.len;
    const accepted = @min(available, input.len);

    if (accepted != 0 and !buffer.ensureCapacity(buffer.len + accepted)) {
        buffer.truncated = true;
        return false;
    }

    if (accepted != 0) {
        @memcpy(buffer.storage[buffer.len..][0..accepted], input[0..accepted]);
        buffer.len += accepted;
    }

    if (accepted != input.len) {
        buffer.truncated = true;
    }

    return accepted == input.len;
}

pub fn bytes(buffer: *const Buffer) []const u8 {
    return buffer.storage[0..buffer.len];
}

pub fn reset(buffer: *Buffer) void {
    std.crypto.secureZero(u8, buffer.storage[0..buffer.len]);
    buffer.len = 0;
    buffer.truncated = false;
}

pub fn deinit(buffer: *Buffer) void {
    if (buffer.storage.len != 0) {
        std.crypto.secureZero(u8, buffer.storage);
        buffer.gpa.free(buffer.storage);
    }

    buffer.storage = &.{};
    buffer.len = 0;
    buffer.truncated = false;
}

fn ensureCapacity(buffer: *Buffer, needed: usize) bool {
    if (needed <= buffer.storage.len) {
        return true;
    }

    var capacity = @min(buffer.max_bytes, @max(@as(usize, 256), buffer.storage.len));
    while (capacity < needed) {
        capacity = @min(buffer.max_bytes, capacity *| 2);
        if (capacity < needed and capacity == buffer.max_bytes) {
            return false;
        }
    }

    const replacement = buffer.gpa.alloc(u8, capacity) catch return false;
    @memcpy(replacement[0..buffer.len], buffer.storage[0..buffer.len]);
    if (buffer.storage.len != 0) {
        std.crypto.secureZero(u8, buffer.storage);
        buffer.gpa.free(buffer.storage);
    }

    buffer.storage = replacement;
    return true;
}
