//! Benchmark only: decides where a fixture's large allocations land, so a
//! paired run can tell whether record placement alone changes a hot path.
//! This is scratch storage for an experiment and not a pool. `pack` never
//! reuses a freed record's bytes and returns its region only in `deinit`;
//! `shift` and `stagger` ask the child for one extra window per allocation.
//!
//! An allocation is controlled when its length reaches the policy's
//! threshold and its alignment fits in the stride. The choice never sees a
//! Zig type: every allocation of that shape is placed, whatever it holds.
const std = @import("std");
const PlacementMode = @import("PlacementMode.zig").PlacementMode;
const PlacementPolicy = @import("PlacementPolicy.zig");
const PlacementAllocator = @This();

/// Controlled allocations alive at once; one more is refused.
pub const capacity = 2048;
/// Address space `pack` reserves. The host backs a page when a record first
/// touches it, so this bounds the experiment and is no measure of its memory.
pub const region_bytes = 1024 * 1024 * 1024;
/// Distinct allocation lengths `stagger` keeps a position for; lengths past
/// these stay at offset zero.
const max_classes = 32;

child: std.mem.Allocator,
policy: PlacementPolicy,
lock: std.atomic.Value(bool) = .init(false),
/// One row per live controlled allocation; a zero address is a free row.
address: [capacity]usize = @splat(0),
/// What the child returned for the row. In `pack` it is the address itself.
base: [capacity]usize = @splat(0),
/// Bytes the caller asked for.
len: [capacity]usize = @splat(0),
class_len: [max_classes]usize = @splat(0),
class_next: [max_classes]usize = @splat(0),
region: []u8 = &.{},
region_used: usize = 0,
/// Controlled allocations made, live or freed since.
placed: usize = 0,
placed_bytes: usize = 0,
live: usize = 0,
/// Controlled requests turned down because the rows or the region ran out.
refused: usize = 0,

/// Builds the placement over `child`. The result must stay where it is once
/// `allocator` has been called.
///
/// ```zig
/// var placement = try PlacementAllocator.init(std.heap.c_allocator, .{ .mode = .stagger, .threshold = 32 * 1024, .stride = 512, .window = std.heap.pageSize() });
/// defer placement.deinit();
/// const gpa = placement.allocator();
/// ```
pub fn init(child: std.mem.Allocator, policy: PlacementPolicy) !PlacementAllocator {
    try policy.validate();

    var self: PlacementAllocator = .{
        .child = child,
        .policy = policy,
    };

    if (policy.mode == .pack) {
        // `rawAlloc` leaves the mapping untouched; `alloc` would fill all of
        // it in safe builds and back every page.
        const mapped = std.heap.page_allocator.rawAlloc(region_bytes, regionAlignment(), @returnAddress()) orelse return error.OutOfMemory;
        self.region = mapped[0..region_bytes];
    }

    return self;
}

/// Returns the region `pack` reserved. Call it after everything allocated
/// through `allocator` was freed; `live` says whether that happened.
///
/// ```zig
/// placement.deinit();
/// ```
pub fn deinit(self: *PlacementAllocator) void {
    if (self.region.len != 0) {
        std.heap.page_allocator.rawFree(self.region, regionAlignment(), @returnAddress());
        self.region = &.{};
    }
}

/// The allocator a fixture builds itself with. `baseline` returns the child
/// itself, so nothing of this file sits between the fixture and its memory.
///
/// ```zig
/// try context.init(io, placement.allocator(), environ, shape);
/// ```
pub fn allocator(self: *PlacementAllocator) std.mem.Allocator {
    if (self.policy.mode == .baseline) {
        return self.child;
    }

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

/// Reports whether `address` starts a live controlled allocation.
///
/// ```zig
/// const controlled = placement.controls(@intFromPtr(pane));
/// ```
pub fn controls(self: *PlacementAllocator, address: usize) bool {
    if (address == 0) {
        return false;
    }

    self.lockRows();
    defer self.unlockRows();

    return self.findRow(address) != null;
}

fn regionAlignment() std.mem.Alignment {
    return .fromByteUnits(std.heap.pageSize());
}

fn lockRows(self: *PlacementAllocator) void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockRows(self: *PlacementAllocator) void {
    self.lock.store(false, .release);
}

fn findRow(self: *const PlacementAllocator, address: usize) ?usize {
    for (self.address, 0..) |candidate, row| {
        if (candidate == address) {
            return row;
        }
    }

    return null;
}

/// The next offset for a record of `len` bytes: each length walks the
/// window's strides on its own, so records of one type never share one.
fn nextStagger(self: *PlacementAllocator, len: usize) usize {
    for (&self.class_len, &self.class_next) |*class, *next| {
        if (class.* == 0) {
            class.* = len;
        }

        if (class.* == len) {
            const position = next.* % self.policy.staggerPositions();
            next.* += 1;
            return position * self.policy.stride;
        }
    }

    return 0;
}

/// Finds memory for one controlled allocation. The rows are locked.
fn land(self: *PlacementAllocator, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?Landing {
    switch (self.policy.mode) {
        .baseline => unreachable,
        .shift, .stagger => {
            const padded = std.math.add(usize, len, self.policy.window) catch return null;
            const offset = if (self.policy.mode == .shift) self.policy.shiftBytes() else self.nextStagger(len);
            const base = self.child.rawAlloc(padded, alignment, ret_addr) orelse return null;
            return .{
                .address = @intFromPtr(base) + offset,
                .base = @intFromPtr(base),
            };
        },
        .pack => {
            const origin = @intFromPtr(self.region.ptr);
            const start = alignment.forward(origin + self.region_used) - origin;
            if (start > self.region.len or len > self.region.len - start) {
                self.refused += 1;
                return null;
            }

            self.region_used = start + len;
            return .{
                .address = origin + start,
                .base = origin + start,
            };
        },
    }
}

fn alloc(erased: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *PlacementAllocator = @ptrCast(@alignCast(erased));
    if (!self.policy.selects(len, alignment)) {
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    self.lockRows();
    defer self.unlockRows();

    const row = self.findRow(0) orelse {
        self.refused += 1;
        return null;
    };

    const landing = self.land(len, alignment, ret_addr) orelse return null;
    self.address[row] = landing.address;
    self.base[row] = landing.base;
    self.len[row] = len;
    self.placed += 1;
    self.placed_bytes += len;
    self.live += 1;
    return @ptrFromInt(landing.address);
}

/// Forgets a controlled allocation and returns what the child gave for it;
/// null when `memory` was never controlled.
fn forget(self: *PlacementAllocator, memory: []u8) ?usize {
    if (memory.len < self.policy.threshold) {
        return null;
    }

    self.lockRows();
    defer self.unlockRows();

    const row = self.findRow(@intFromPtr(memory.ptr)) orelse return null;
    std.debug.assert(self.len[row] == memory.len);
    self.address[row] = 0;
    self.live -= 1;
    return self.base[row];
}

fn resize(erased: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *PlacementAllocator = @ptrCast(@alignCast(erased));
    if (memory.len >= self.policy.threshold and self.controls(@intFromPtr(memory.ptr))) {
        return false;
    }

    return self.child.rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(erased: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *PlacementAllocator = @ptrCast(@alignCast(erased));
    if (memory.len >= self.policy.threshold and self.controls(@intFromPtr(memory.ptr))) {
        return null;
    }

    return self.child.rawRemap(memory, alignment, new_len, ret_addr);
}

fn free(erased: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *PlacementAllocator = @ptrCast(@alignCast(erased));
    const base = self.forget(memory) orelse {
        self.child.rawFree(memory, alignment, ret_addr);
        return;
    };

    if (self.policy.mode == .pack) {
        return;
    }

    const padded: [*]u8 = @ptrFromInt(base);
    self.child.rawFree(padded[0 .. memory.len + self.policy.window], alignment, ret_addr);
}

/// Where one controlled allocation starts and what the child gave for it.
const Landing = struct {
    address: usize,
    base: usize,
};

const test_policy: PlacementPolicy = .{
    .mode = .stagger,
    .threshold = 1024,
    .stride = 64,
    .window = 1024,
};

fn testPolicy(mode: PlacementMode) PlacementPolicy {
    var policy = test_policy;
    policy.mode = mode;
    return policy;
}

test "stagger gives each record of one length its own aligned offset inside the window" {
    var placement = try PlacementAllocator.init(std.testing.allocator, test_policy);
    defer placement.deinit();
    const gpa = placement.allocator();

    const positions = comptime test_policy.staggerPositions();
    var records: [positions + 2][]align(64) u8 = undefined;
    for (&records, 0..) |*record, index| {
        record.* = try gpa.alignedAlloc(u8, .@"64", 2048);
        @memset(record.*, @intCast(index));
        const row = placement.findRow(@intFromPtr(record.ptr)).?;
        const offset = placement.address[row] - placement.base[row];
        try std.testing.expectEqual((index % positions) * test_policy.stride, offset);
        try std.testing.expect(offset < test_policy.window);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(record.ptr) % 64);
        try std.testing.expect(placement.controls(@intFromPtr(record.ptr)));
    }

    try std.testing.expectEqual(records.len, placement.live);
    for (records, 0..) |record, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), record[record.len - 1]);
        gpa.free(record);
    }

    try std.testing.expectEqual(@as(usize, 0), placement.live);
    try std.testing.expectEqual(records.len, placement.placed);
    try std.testing.expectEqual(records.len * 2048, placement.placed_bytes);
}

test "stagger walks each allocation length separately" {
    var placement = try PlacementAllocator.init(std.testing.allocator, test_policy);
    defer placement.deinit();
    const gpa = placement.allocator();

    const first = try gpa.alloc(u8, 2048);
    defer gpa.free(first);
    const other = try gpa.alloc(u8, 4096);
    defer gpa.free(other);
    const second = try gpa.alloc(u8, 2048);
    defer gpa.free(second);

    for ([_][]u8{ first, other, second }, [_]usize{ 0, 0, test_policy.stride }) |record, expected| {
        const row = placement.findRow(@intFromPtr(record.ptr)).?;
        try std.testing.expectEqual(expected, placement.address[row] - placement.base[row]);
    }
}

test "shift moves every controlled allocation by the same offset" {
    var placement = try PlacementAllocator.init(std.testing.allocator, testPolicy(.shift));
    defer placement.deinit();
    const gpa = placement.allocator();

    var records: [5][]u8 = undefined;
    for (&records) |*record| {
        record.* = try gpa.alloc(u8, 4096);
        @memset(record.*, 7);
        const row = placement.findRow(@intFromPtr(record.ptr)).?;
        try std.testing.expectEqual(test_policy.shiftBytes(), placement.address[row] - placement.base[row]);
    }

    for (records) |record| {
        gpa.free(record);
    }

    try std.testing.expectEqual(@as(usize, 0), placement.live);
}

test "pack carves aligned records back to back and returns its region at teardown" {
    var placement = try PlacementAllocator.init(std.testing.allocator, testPolicy(.pack));
    const gpa = placement.allocator();

    const first = try gpa.alloc(u8, 1500);
    const second = try gpa.alignedAlloc(u8, .@"64", 3000);
    const third = try gpa.alloc(u64, 200);
    @memset(first, 1);
    @memset(second, 2);
    @memset(third, 3);

    const origin = @intFromPtr(placement.region.ptr);
    try std.testing.expectEqual(origin, @intFromPtr(first.ptr));
    try std.testing.expectEqual(std.mem.alignForward(usize, origin + 1500, 64), @intFromPtr(second.ptr));
    try std.testing.expectEqual(std.mem.alignForward(usize, @intFromPtr(second.ptr) + 3000, @alignOf(u64)), @intFromPtr(third.ptr));
    try std.testing.expect(@intFromPtr(third.ptr) + 1600 <= origin + placement.region.len);
    try std.testing.expectEqual(@intFromPtr(third.ptr) + 1600 - origin, placement.region_used);

    gpa.free(first);
    const used = placement.region_used;
    const fourth = try gpa.alloc(u8, 1500);
    try std.testing.expect(@intFromPtr(fourth.ptr) >= origin + used);

    gpa.free(second);
    gpa.free(third);
    gpa.free(fourth);
    try std.testing.expectEqual(@as(usize, 0), placement.live);
    try std.testing.expectEqual(@as(usize, 4), placement.placed);

    placement.deinit();
    try std.testing.expectEqual(@as(usize, 0), placement.region.len);
}

test "allocations below the threshold or above the stride's alignment go to the child untouched" {
    inline for (.{ PlacementMode.shift, PlacementMode.stagger, PlacementMode.pack }) |mode| {
        var placement = try PlacementAllocator.init(std.testing.allocator, testPolicy(mode));
        defer placement.deinit();
        const gpa = placement.allocator();

        const small = try gpa.alloc(u8, test_policy.threshold - 1);
        defer gpa.free(small);
        const aligned = try gpa.alignedAlloc(u8, .fromByteUnits(128), 4096);
        defer gpa.free(aligned);

        try std.testing.expect(!placement.policy.selects(small.len, .@"1"));
        try std.testing.expect(!placement.policy.selects(aligned.len, .fromByteUnits(128)));
        try std.testing.expect(placement.policy.selects(test_policy.threshold, .@"64"));
        try std.testing.expect(!placement.controls(@intFromPtr(small.ptr)));
        try std.testing.expect(!placement.controls(@intFromPtr(aligned.ptr)));
        try std.testing.expectEqual(@as(usize, 0), placement.placed);
    }
}

test "a controlled allocation is never resized in place and still grows through a copy" {
    inline for (.{ PlacementMode.shift, PlacementMode.stagger, PlacementMode.pack }) |mode| {
        var placement = try PlacementAllocator.init(std.testing.allocator, testPolicy(mode));
        defer placement.deinit();
        const gpa = placement.allocator();

        var record = try gpa.alloc(u8, 2048);
        @memset(record, 9);
        try std.testing.expect(!gpa.resize(record, 1024));
        try std.testing.expect(gpa.remap(record, 4096) == null);

        record = try gpa.realloc(record, 8192);
        try std.testing.expectEqual(@as(u8, 9), record[2047]);
        try std.testing.expectEqual(@as(usize, 2), placement.placed);
        try std.testing.expectEqual(@as(usize, 1), placement.live);

        gpa.free(record);
        try std.testing.expectEqual(@as(usize, 0), placement.live);
    }
}

test "baseline hands out the child itself and controls nothing" {
    var placement = try PlacementAllocator.init(std.testing.allocator, testPolicy(.baseline));
    defer placement.deinit();
    const gpa = placement.allocator();

    try std.testing.expectEqual(std.testing.allocator.ptr, gpa.ptr);
    try std.testing.expectEqual(std.testing.allocator.vtable, gpa.vtable);
    try std.testing.expect(!placement.policy.selects(1 << 20, .@"1"));

    const record = try gpa.alloc(u8, 4096);
    defer gpa.free(record);
    try std.testing.expect(!placement.controls(@intFromPtr(record.ptr)));
    try std.testing.expectEqual(@as(usize, 0), placement.placed);
}

test "a full table and an exhausted region refuse instead of placing unseen" {
    var placement = try PlacementAllocator.init(std.testing.allocator, testPolicy(.stagger));
    defer placement.deinit();
    const gpa = placement.allocator();

    var records: [capacity][]u8 = undefined;
    for (&records) |*record| {
        record.* = try gpa.alloc(u8, test_policy.threshold);
    }

    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, test_policy.threshold));
    try std.testing.expectEqual(@as(usize, 1), placement.refused);
    for (records) |record| {
        gpa.free(record);
    }

    try std.testing.expectEqual(@as(usize, 0), placement.live);

    var packed_placement = try PlacementAllocator.init(std.testing.allocator, testPolicy(.pack));
    defer packed_placement.deinit();
    try std.testing.expectError(error.OutOfMemory, packed_placement.allocator().alloc(u8, region_bytes + 1));
    try std.testing.expectEqual(@as(usize, 1), packed_placement.refused);
    try std.testing.expectEqual(@as(usize, 0), packed_placement.region_used);
}

test "a policy that cannot keep records aligned is rejected" {
    var policy = test_policy;
    policy.threshold = 0;
    try std.testing.expectError(error.InvalidPlacementThreshold, PlacementAllocator.init(std.testing.allocator, policy));

    policy = test_policy;
    policy.stride = 48;
    try std.testing.expectError(error.InvalidPlacementStride, PlacementAllocator.init(std.testing.allocator, policy));

    policy = test_policy;
    policy.window = 3000;
    try std.testing.expectError(error.InvalidPlacementWindow, PlacementAllocator.init(std.testing.allocator, policy));

    policy = test_policy;
    policy.window = 2 * policy.stride;
    try std.testing.expectError(error.InvalidPlacementWindow, PlacementAllocator.init(std.testing.allocator, policy));
}
