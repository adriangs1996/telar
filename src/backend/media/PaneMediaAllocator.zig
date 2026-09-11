/// Allocator used by VT stream effects and KGP. Charging allocations before
/// forwarding them to the child allocator makes compressed input, decoded
/// pixels, parser buffers and IPC transfer snapshots obey one hard budget.
const PaneMediaAllocator = @This();
const std = @import("std");
const GraphicsBudget = @import("GraphicsBudget.zig");
const core = @import("telar-core");
child: std.mem.Allocator,
budget: *GraphicsBudget,
limit: usize,
used: usize = 0,
/// Read-only mappings of runtime-owned shared objects that hold the
/// pixels of emulator images. The emulator stores a one-byte placeholder
/// as the image data and frees it through this allocator; freeing the
/// placeholder unmaps the object and releases its reservation. The
/// emulator never reads pixels here, and a placeholder keeps the
/// allocator's safety-checked scribble on freed memory away from an
/// object a client or host may still be reading. Touched only by
/// whoever holds the pane's media borrow.
mappings: [core.graphics.max_images_per_pane]?Mapping = @splat(null),

pub const Mapping = struct {
    placeholder: [*]const u8,
    pixels: []align(std.heap.page_size_min) u8,
};

pub fn init(child: std.mem.Allocator, budget: *GraphicsBudget, limit: usize) PaneMediaAllocator {
    return .{ .child = child, .budget = budget, .limit = limit };
}

/// Registers a mapping already reserved against the budget behind the
/// placeholder the emulator will free. Returns false when no slot is free.
///
/// ```zig
/// if (!media.adoptMapping(placeholder, map)) return error.MappingLimitReached;
/// ```
pub fn adoptMapping(media: *PaneMediaAllocator, placeholder: []const u8, pixels: []align(std.heap.page_size_min) u8) bool {
    for (&media.mappings) |*slot| {
        if (slot.* != null) {
            continue;
        }
        slot.* = .{ .placeholder = placeholder.ptr, .pixels = pixels };
        return true;
    }
    return false;
}

/// Resolves emulator image data to the pixels it stands for: the mapped
/// object behind a placeholder, or the data itself.
///
/// ```zig
/// const pixels = pane.media_allocator.imagePixels(image.data.bytes()) orelse continue;
/// ```
pub fn imagePixels(media: *const PaneMediaAllocator, data: ?[]const u8) ?[]const u8 {
    const bytes = data orelse return null;
    for (media.mappings) |slot| {
        const mapping = slot orelse continue;
        if (mapping.placeholder == bytes.ptr) {
            return mapping.pixels;
        }
    }
    return bytes;
}

fn releaseMapping(media: *PaneMediaAllocator, memory: []u8) void {
    for (&media.mappings) |*slot| {
        const mapping = slot.* orelse continue;
        if (mapping.placeholder != memory.ptr) {
            continue;
        }
        std.posix.munmap(mapping.pixels);
        media.releaseManual(mapping.pixels.len);
        slot.* = null;
        return;
    }
}

fn isMapped(media: *const PaneMediaAllocator, memory: []u8) bool {
    for (media.mappings) |slot| {
        const mapping = slot orelse continue;
        if (mapping.placeholder == memory.ptr) {
            return true;
        }
    }
    return false;
}

pub fn allocator(media: *PaneMediaAllocator) std.mem.Allocator {
    // Callback signatures are fixed by `std.mem.Allocator.VTable`.
    return .{ .ptr = media, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

pub fn reserveManual(media: *PaneMediaAllocator, bytes: usize) bool {
    return media.budget.reserve(media, bytes);
}

pub fn releaseManual(media: *PaneMediaAllocator, bytes: usize) void {
    media.budget.release(media, bytes);
}

pub fn detach(media: *PaneMediaAllocator) void {
    media.budget.releaseAll(media);
}

// codestyle: allow(maximum-parameter-count)
fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
    if (!media.reserveManual(len)) {
        return null;
    }
    return media.child.rawAlloc(len, alignment, ret_addr) orelse {
        media.releaseManual(len);
        return null;
    };
}

// codestyle: allow(maximum-parameter-count)
fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
    if (media.isMapped(memory)) {
        return false;
    }
    if (new_len > memory.len and !media.reserveManual(new_len - memory.len)) {
        return false;
    }
    if (!media.child.rawResize(memory, alignment, new_len, ret_addr)) {
        if (new_len > memory.len) {
            media.releaseManual(new_len - memory.len);
        }
        return false;
    }
    if (new_len < memory.len) {
        media.releaseManual(memory.len - new_len);
    }
    return true;
}

// codestyle: allow(maximum-parameter-count)
fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
    if (media.isMapped(memory)) {
        return null;
    }
    if (new_len > memory.len and !media.reserveManual(new_len - memory.len)) {
        return null;
    }
    const result = media.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
        if (new_len > memory.len) {
            media.releaseManual(new_len - memory.len);
        }
        return null;
    };
    if (new_len < memory.len) {
        media.releaseManual(memory.len - new_len);
    }
    return result;
}

// codestyle: allow(maximum-parameter-count)
fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
    media.releaseMapping(memory);
    media.child.rawFree(memory, alignment, ret_addr);
    media.releaseManual(memory.len);
}
