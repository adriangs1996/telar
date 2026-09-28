//! Zig 0.16's `std.heap.SmpAllocator` (MIT) with one change: before mapping
//! a fresh slab, an allocation searches the free lists of every thread slot
//! instead of one other slot.
//!
//! Each thread frees into the slot it holds, and a thread moves to another
//! slot whenever its own is locked. Searching one other slot left memory freed
//! on the remaining slots unreachable by the threads that allocate that size,
//! and slabs are never unmapped, so a runtime that allocates on one thread and
//! frees on another grew with every history batch. Searching every slot keeps
//! the slabs of a class near its peak live bytes, rounded up to the class; a
//! slot locked during the search is skipped. The search costs one `tryLock`
//! per slot and runs only when a slab would otherwise be mapped, once per
//! 64 KiB of a class.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PageAllocator = std.heap.PageAllocator;

const max_slot_count = 128;
const slab_len: usize = @max(std.heap.page_size_max, 64 * 1024);
/// Free lists store a pointer in each free slot, so the smallest class holds one.
const min_class = std.math.log2(@sizeOf(usize));
const size_class_count = std.math.log2(slab_len) - min_class;

/// One thread slot: a free list and a bump address per size class.
const Slot = struct {
    /// Keeps two slots off one cache line.
    _: void align(std.atomic.cache_line) = {},
    mutex: std.atomic.Mutex = .unlocked,
    /// The next unused address of the slab being carved, per class. A
    /// multiple of `slab_len` means the slab is used up.
    next_addrs: [size_class_count]usize = @splat(0),
    /// The most recently freed slot, per class; each free slot stores the next.
    frees: [size_class_count]usize = @splat(0),
};

var slots: [max_slot_count]Slot = @splat(.{});
var slot_count: u32 = 0;
var mapped_slabs: usize = 0;
threadlocal var slot_index: u32 = 0;

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

/// The process-wide slab heap. Every thread may use it; it keeps no state
/// per caller.
///
/// ```zig
/// const bytes = try slabheap.allocator.alloc(u8, 256);
/// defer slabheap.allocator.free(bytes);
/// ```
pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    _ = context;
    _ = return_address;
    const class = sizeClassIndex(len, alignment);
    if (class >= size_class_count) {
        return PageAllocator.map(len, alignment);
    }

    const slot_size = slotSize(class);
    var slot = lockSlot();
    var searched: u32 = 1;
    while (true) {
        if (takeFreeSlot(slot, class, slot_size)) |address| {
            slot.mutex.unlock();
            return address;
        }

        if (searched >= slotCount()) {
            defer slot.mutex.unlock();
            return mapSlab(slot, class, slot_size);
        }

        slot.mutex.unlock();
        slot = lockNextSlot();
        searched += 1;
    }
}

fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) bool {
    _ = context;
    _ = return_address;
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);
    if (class >= size_class_count) {
        if (new_class < size_class_count) {
            return false;
        }

        return PageAllocator.realloc(memory, alignment, new_len, false) != null;
    }

    return new_class == class;
}

fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    _ = context;
    _ = return_address;
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);
    if (class >= size_class_count) {
        if (new_class < size_class_count) {
            return null;
        }

        return PageAllocator.realloc(memory, alignment, new_len, true);
    }

    return if (new_class == class) memory.ptr else null;
}

fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
    _ = context;
    _ = return_address;
    const class = sizeClassIndex(memory.len, alignment);
    if (class >= size_class_count) {
        return PageAllocator.unmap(@alignCast(memory));
    }

    const node: *usize = @ptrCast(@alignCast(memory.ptr));
    const slot = lockSlot();
    defer slot.mutex.unlock();

    node.* = slot.frees[class];
    slot.frees[class] = @intFromPtr(node);
}

fn takeFreeSlot(slot: *Slot, class: usize, slot_size: usize) ?[*]u8 {
    const free_address = slot.frees[class];
    if (free_address != 0) {
        const node: *usize = @ptrFromInt(free_address);
        slot.frees[class] = node.*;
        return @ptrFromInt(free_address);
    }

    const next_address = slot.next_addrs[class];
    if (next_address % slab_len != 0) {
        slot.next_addrs[class] = next_address + slot_size;
        return @ptrFromInt(next_address);
    }

    return null;
}

fn mapSlab(slot: *Slot, class: usize, slot_size: usize) ?[*]u8 {
    const slab = PageAllocator.map(slab_len, .fromByteUnits(slab_len)) orelse return null;
    slot.next_addrs[class] = @intFromPtr(slab) + slot_size;
    _ = @atomicRmw(usize, &mapped_slabs, .Add, 1, .monotonic);
    return slab;
}

fn lockSlot() *Slot {
    const own = &slots[slot_index];
    if (own.mutex.tryLock()) {
        return own;
    }

    return lockNextSlot();
}

fn lockNextSlot() *Slot {
    const count = slotCount();
    var index = slot_index;
    while (true) {
        index = (index + 1) % count;
        const slot = &slots[index];
        if (slot.mutex.tryLock()) {
            slot_index = index;
            return slot;
        }
    }
}

fn slotCount() u32 {
    const cached = @atomicLoad(u32, &slot_count, .unordered);
    if (cached != 0) {
        return cached;
    }

    const cpus = std.Thread.getCpuCount() catch max_slot_count;
    const count: u32 = @intCast(@min(cpus, max_slot_count));
    return @cmpxchgStrong(u32, &slot_count, 0, count, .monotonic, .monotonic) orelse count;
}

fn sizeClassIndex(len: usize, alignment: Alignment) usize {
    return @max(@bitSizeOf(usize) - @clz(len - 1), @intFromEnum(alignment), min_class) - min_class;
}

fn slotSize(class: usize) usize {
    return @as(usize, 1) << @intCast(class + min_class);
}

test "the slab heap passes the standard allocator checks" {
    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}

test "an allocation reuses slots freed two thread slots away before mapping a slab" {
    // Three slots put the freed memory where SmpAllocator's single-slot
    // search never looks.
    @atomicStore(u32, &slot_count, 3, .monotonic);
    slot_index = 0;
    const len = slab_len / 2;

    const first = try allocator.alloc(u8, len);
    const second = try allocator.alloc(u8, len);
    try std.testing.expect(slots[0].mutex.tryLock());
    try std.testing.expect(slots[1].mutex.tryLock());
    const freeing = try std.Thread.spawn(.{}, freeBoth, .{ first, second });
    freeing.join();
    slots[1].mutex.unlock();
    slots[0].mutex.unlock();

    slot_index = 0;
    const mapped = @atomicLoad(usize, &mapped_slabs, .monotonic);
    const third = try allocator.alloc(u8, len);
    const fourth = try allocator.alloc(u8, len);
    defer allocator.free(third);
    defer allocator.free(fourth);

    try std.testing.expectEqual(mapped, @atomicLoad(usize, &mapped_slabs, .monotonic));
    try std.testing.expect(third.ptr == second.ptr or third.ptr == first.ptr);
    try std.testing.expect(fourth.ptr == second.ptr or fourth.ptr == first.ptr);
}

fn freeBoth(first: []u8, second: []u8) void {
    allocator.free(first);
    allocator.free(second);
}
