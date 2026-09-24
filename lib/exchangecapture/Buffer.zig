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

pub fn append(self: *Buffer, input: []const u8) bool {
    const available = self.max_bytes -| self.len;
    const accepted = @min(available, input.len);

    if (accepted != 0 and !self.ensureCapacity(self.len + accepted)) {
        self.truncated = true;
        return false;
    }

    if (accepted != 0) {
        @memcpy(self.storage[self.len..][0..accepted], input[0..accepted]);
        self.len += accepted;
    }

    if (accepted != input.len) {
        self.truncated = true;
    }

    return accepted == input.len;
}

pub fn bytes(self: *const Buffer) []const u8 {
    return self.storage[0..self.len];
}

pub fn reset(self: *Buffer) void {
    std.crypto.secureZero(u8, self.storage[0..self.len]);
    self.len = 0;
    self.truncated = false;
}

pub fn deinit(self: *Buffer) void {
    if (self.storage.len != 0) {
        std.crypto.secureZero(u8, self.storage);
        self.gpa.free(self.storage);
    }

    self.storage = &.{};
    self.len = 0;
    self.truncated = false;
}

fn ensureCapacity(self: *Buffer, needed: usize) bool {
    if (needed <= self.storage.len) {
        return true;
    }

    var capacity = @min(self.max_bytes, @max(@as(usize, 256), self.storage.len));
    while (capacity < needed) {
        capacity = @min(self.max_bytes, capacity *| 2);
        if (capacity < needed and capacity == self.max_bytes) {
            return false;
        }
    }

    const replacement = self.gpa.alloc(u8, capacity) catch return false;
    @memcpy(replacement[0..self.len], self.storage[0..self.len]);
    if (self.storage.len != 0) {
        std.crypto.secureZero(u8, self.storage);
        self.gpa.free(self.storage);
    }

    self.storage = replacement;
    return true;
}
