//! A test-only allocator with a hard limit on the bytes it holds live. An
//! allocation or growth that would take the live bytes past `limit` is
//! refused before the child is asked, so the refused bytes are never
//! reserved. The imaging fuzz roots put it between their
//! `std.testing.FailingAllocator` and `std.testing.allocator`, which keeps
//! the testing allocator's leak checks; nothing else imports it.
const std = @import("std");
const BoundedTestAllocator = @This();

child: std.mem.Allocator,
limit: usize,
live_bytes: usize = 0,
peak_bytes: usize = 0,
refusals: usize = 0,

/// Example: `var bounded: BoundedTestAllocator = .init(std.testing.allocator, budget);`
pub fn init(child: std.mem.Allocator, limit: usize) BoundedTestAllocator {
    return .{
        .child = child,
        .limit = limit,
    };
}

/// Example: `var failing: FailingAllocator = .init(bounded.allocator(), .{});`
pub fn allocator(self: *BoundedTestAllocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

/// Whether `additional` bytes fit under the limit; `live_bytes` never
/// passes it, so the subtraction cannot wrap.
fn admits(self: *const BoundedTestAllocator, additional: usize) bool {
    return additional <= self.limit - self.live_bytes;
}

/// Records a successful change from `old_len` to `new_len` live bytes.
fn account(self: *BoundedTestAllocator, old_len: usize, new_len: usize) void {
    if (new_len >= old_len) {
        self.live_bytes += new_len - old_len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return;
    }

    self.live_bytes -= old_len - new_len;
}

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    const self: *BoundedTestAllocator = @ptrCast(@alignCast(context));
    if (!self.admits(len)) {
        self.refusals += 1;
        return null;
    }

    const memory = self.child.rawAlloc(
        len,
        alignment,
        return_address,
    ) orelse return null;
    self.account(0, len);
    return memory;
}

fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
    const self: *BoundedTestAllocator = @ptrCast(@alignCast(context));
    if (new_len > memory.len and !self.admits(new_len - memory.len)) {
        self.refusals += 1;
        return false;
    }

    const resized = self.child.rawResize(
        memory,
        alignment,
        new_len,
        return_address,
    );
    if (!resized) {
        return false;
    }

    self.account(memory.len, new_len);
    return true;
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    const self: *BoundedTestAllocator = @ptrCast(@alignCast(context));
    if (new_len > memory.len and !self.admits(new_len - memory.len)) {
        self.refusals += 1;
        return null;
    }

    const remapped = self.child.rawRemap(
        memory,
        alignment,
        new_len,
        return_address,
    ) orelse return null;
    self.account(memory.len, new_len);
    return remapped;
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    const self: *BoundedTestAllocator = @ptrCast(@alignCast(context));
    self.child.rawFree(
        memory,
        alignment,
        return_address,
    );
    self.account(memory.len, 0);
}

test "a request past the limit is refused before the child reserves it" {
    var backing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var bounded: BoundedTestAllocator = .init(backing.allocator(), 64);
    const gpa = bounded.allocator();

    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 65));
    try std.testing.expectEqual(1, bounded.refusals);
    try std.testing.expectEqual(0, backing.allocations);

    const first = try gpa.alloc(u8, 40);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 25));
    try std.testing.expectEqual(2, bounded.refusals);
    try std.testing.expectEqual(1, backing.allocations);

    const second = try gpa.alloc(u8, 24);
    try std.testing.expectEqual(64, bounded.live_bytes);
    try std.testing.expectEqual(64, bounded.peak_bytes);
    try std.testing.expect(!gpa.resize(second, 25));
    try std.testing.expectEqual(null, gpa.remap(second, 25));
    try std.testing.expectEqual(4, bounded.refusals);
    try std.testing.expectEqual(2, backing.allocations);

    gpa.free(first);
    gpa.free(second);
    try std.testing.expectEqual(0, bounded.live_bytes);
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
