//! A copy of Zig 0.16's `std.heap.SmpAllocator` (MIT) that differs in two
//! ways: its state is an instance instead of a process global, so tests own
//! theirs, and an allocation searches every other thread slot before it maps
//! a slab instead of one other slot. Resynchronize it with
//! `lib/std/heap/SmpAllocator.zig` whenever telar moves to a newer Zig.
//!
//! Each thread frees into the slot it holds, and a thread moves to another
//! slot whenever its own is locked. With one other slot searched, memory
//! freed on the remaining slots stayed out of reach of the threads that
//! allocate that size, and slabs are never unmapped, so a runtime that
//! allocates on one thread and frees on another grew with every history
//! batch.
//!
//! Here, when a thread's own slot has nothing for a class, it releases it and
//! visits each other slot once. It spins a bounded while for a slot another
//! thread holds and skips it after that, so an allocation never waits for a
//! holder that was preempted; it never holds two slots, so nothing can
//! deadlock. The first slot with a free slot or unused slab space serves the
//! allocation and becomes the thread's slot. Only when no visited slot had
//! any is a slab mapped, outside every lock, so the slabs of a class stay
//! near its peak live bytes, rounded up to the class, plus what sat in slots
//! skipped at that moment. Skipping a busy slot at once let a thread that
//! allocates while others free keep mapping slabs; waiting without a bound
//! kept an allocation waiting 0.3 to 0.5 ms at worst in a stress test. The
//! search costs one lock per slot, on the allocations that find their own
//! slot empty.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PageAllocator = std.heap.PageAllocator;
const SlabHeap = @This();

const max_slot_count = 128;
const slab_len: usize = @max(std.heap.page_size_max, 64 * 1024);
/// Free lists store a pointer in each free slot, so the smallest class holds one.
const min_class = std.math.log2(@sizeOf(usize));
const size_class_count = std.math.log2(slab_len) - min_class;
/// How long to spin for a busy slot before skipping it: a slot is held for
/// a few instructions unless its holder was preempted.
const spins_before_skip = 128;

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

slots: [max_slot_count]Slot = @splat(.{}),
/// Slots in use: the CPU count, read on first use unless set beforehand.
slot_count: u32 = 0,
/// Slabs mapped so far; slabs are never unmapped.
mapped_slabs: usize = 0,

/// The slot this thread last held, shared by every heap of the process.
threadlocal var slot_index: u32 = 0;

pub const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

/// An allocator over this heap, which must outlive every block it returns.
///
/// ```zig
/// var heap: SlabHeap = .{};
/// const bytes = try heap.allocator().alloc(u8, 256);
/// ```
pub fn allocator(self: *SlabHeap) Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    _ = return_address;
    const self: *SlabHeap = @ptrCast(@alignCast(context));
    const class = sizeClassIndex(len, alignment);
    if (class >= size_class_count) {
        return PageAllocator.map(len, alignment);
    }

    const slot_size = slotSize(class);
    const own = self.lockSlot();
    if (takeFreeSlot(own, class, slot_size)) |address| {
        own.mutex.unlock();
        return address;
    }

    own.mutex.unlock();
    if (self.takeFromOtherSlot(class, slot_size)) |address| {
        return address;
    }

    return self.mapSlab(class, slot_size);
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
    _ = return_address;
    const self: *SlabHeap = @ptrCast(@alignCast(context));
    const class = sizeClassIndex(memory.len, alignment);
    if (class >= size_class_count) {
        return PageAllocator.unmap(@alignCast(memory));
    }

    const node: *usize = @ptrCast(@alignCast(memory.ptr));
    const slot = self.lockSlot();
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

// Visits each other slot once, skipping one held past `spins_before_skip`.
// The caller holds no slot meanwhile, so no two slots are ever held together.
fn takeFromOtherSlot(self: *SlabHeap, class: usize, slot_size: usize) ?[*]u8 {
    const count = self.slotCount();
    const start = slot_index;
    for (1..count) |offset| {
        const index: u32 = @intCast((start + offset) % count);
        const other = &self.slots[index];
        if (!lockWithin(other)) {
            continue;
        }

        defer other.mutex.unlock();
        if (takeFreeSlot(other, class, slot_size)) |address| {
            slot_index = index;
            return address;
        }
    }

    return null;
}

fn lockWithin(slot: *Slot) bool {
    var spins: u32 = 0;
    while (!slot.mutex.tryLock()) {
        if (spins == spins_before_skip) {
            return false;
        }

        spins += 1;
        std.atomic.spinLoopHint();
    }

    return true;
}

// Maps before taking a slot, so no thread spins on one held across mmap. A
// slot that meanwhile received a free serves it and the new slab goes back.
fn mapSlab(self: *SlabHeap, class: usize, slot_size: usize) ?[*]u8 {
    const slab = PageAllocator.map(slab_len, .fromByteUnits(slab_len)) orelse return null;
    const slot = self.lockSlot();
    if (takeFreeSlot(slot, class, slot_size)) |address| {
        slot.mutex.unlock();
        PageAllocator.unmap(@alignCast(slab[0..slab_len]));
        return address;
    }

    slot.next_addrs[class] = @intFromPtr(slab) + slot_size;
    slot.mutex.unlock();
    _ = @atomicRmw(usize, &self.mapped_slabs, .Add, 1, .monotonic);
    return slab;
}

fn lockSlot(self: *SlabHeap) *Slot {
    const count = self.slotCount();
    var index = if (slot_index < count) slot_index else 0;
    while (true) {
        const slot = &self.slots[index];
        if (slot.mutex.tryLock()) {
            slot_index = index;
            return slot;
        }

        index = (index + 1) % count;
    }
}

fn slotCount(self: *SlabHeap) u32 {
    const cached = @atomicLoad(u32, &self.slot_count, .unordered);
    if (cached != 0) {
        return cached;
    }

    const cpus = std.Thread.getCpuCount() catch max_slot_count;
    const count: u32 = @intCast(@min(cpus, max_slot_count));
    return @cmpxchgStrong(u32, &self.slot_count, 0, count, .monotonic, .monotonic) orelse count;
}

fn sizeClassIndex(len: usize, alignment: Alignment) usize {
    return @max(@bitSizeOf(usize) - @clz(len - 1), @intFromEnum(alignment), min_class) - min_class;
}

fn slotSize(class: usize) usize {
    return @as(usize, 1) << @intCast(class + min_class);
}

fn mappedSlabs(self: *SlabHeap) usize {
    return @atomicLoad(usize, &self.mapped_slabs, .monotonic);
}

test "the slab heap passes the standard allocator checks" {
    var heap: SlabHeap = .{};
    try std.heap.testAllocator(heap.allocator());
    try std.heap.testAllocatorAligned(heap.allocator());
    try std.heap.testAllocatorLargeAlignment(heap.allocator());
    try std.heap.testAllocatorAlignedShrink(heap.allocator());
}

test "an allocation reuses slots freed two thread slots away before mapping a slab" {
    // Three slots put the freed memory where SmpAllocator's single-slot
    // search never looks.
    var heap: SlabHeap = .{ .slot_count = 3 };
    const gpa = heap.allocator();
    const len = slab_len / 2;
    slot_index = 0;

    const first = try gpa.alloc(u8, len);
    const second = try gpa.alloc(u8, len);
    try std.testing.expect(heap.slots[0].mutex.tryLock());
    try std.testing.expect(heap.slots[1].mutex.tryLock());
    const freeing = try std.Thread.spawn(.{}, freeBoth, .{ gpa, first, second });
    freeing.join();
    heap.slots[1].mutex.unlock();
    heap.slots[0].mutex.unlock();

    slot_index = 0;
    const mapped = heap.mappedSlabs();
    const third = try gpa.alloc(u8, len);
    const fourth = try gpa.alloc(u8, len);
    defer gpa.free(third);
    defer gpa.free(fourth);

    try std.testing.expectEqual(mapped, heap.mappedSlabs());
    try std.testing.expect(third.ptr == second.ptr or third.ptr == first.ptr);
    try std.testing.expect(fourth.ptr == second.ptr or fourth.ptr == first.ptr);
}

fn freeBoth(gpa: Allocator, first: []u8, second: []u8) void {
    gpa.free(first);
    gpa.free(second);
}

/// Blocks handed from the allocating thread to one freeing thread.
const Handoff = struct {
    const capacity = 256;

    blocks: [capacity][]u8 = undefined,
    /// Written by the allocating thread.
    head: std.atomic.Value(usize) = .init(0),
    /// Written by the freeing thread.
    tail: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    fn push(self: *Handoff, block: []u8) void {
        const head = self.head.load(.monotonic);
        while (head - self.tail.load(.acquire) == capacity) {
            std.Thread.yield() catch {};
        }

        self.blocks[head % capacity] = block;
        self.head.store(head + 1, .release);
    }

    fn drain(self: *Handoff, gpa: Allocator) void {
        var tail = self.tail.load(.monotonic);
        while (true) {
            if (tail == self.head.load(.acquire)) {
                if (self.done.load(.acquire) and tail == self.head.load(.acquire)) {
                    return;
                }

                std.Thread.yield() catch {};
                continue;
            }

            gpa.free(self.blocks[tail % capacity]);
            tail += 1;
            self.tail.store(tail, .release);
        }
    }
};

test "one thread allocating while three free keeps the mapped slabs near the live bytes" {
    const freeing_threads = 3;
    const block_len = 256;
    const block_count = 200_000;
    var heap: SlabHeap = .{ .slot_count = freeing_threads + 1 };
    const gpa = heap.allocator();
    slot_index = 0;

    var handoffs: [freeing_threads]Handoff = @splat(.{});
    var threads: [freeing_threads]std.Thread = undefined;
    for (&handoffs, &threads) |*handoff, *thread| {
        thread.* = try std.Thread.spawn(.{}, Handoff.drain, .{ handoff, gpa });
    }

    for (0..block_count) |index| {
        const block = try gpa.alloc(u8, block_len);
        handoffs[index % freeing_threads].push(block);
    }

    for (&handoffs, &threads) |*handoff, thread| {
        handoff.done.store(true, .release);
        thread.join();
    }

    // At most 768 blocks are alive at once, 3 slabs; never reusing a block
    // would map 782. SmpAllocator's single-slot search mapped 39 to 236 here,
    // and skipping a busy slot at once 5 to 85.
    const live_slabs = freeing_threads * Handoff.capacity * block_len / slab_len;
    try std.testing.expect(heap.mappedSlabs() <= live_slabs + heap.slot_count);
}
