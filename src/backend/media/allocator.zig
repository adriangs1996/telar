//! Bounded media allocations and runtime-wide budget accounting.

const std = @import("std");
const core = @import("telar-core");

/// Runtime-owned KGP budgets. Values may be lowered by future user
/// configuration but never raised past the protocol hard limits shared with
/// clients, so every snapshot remains decodable by every compatible client.
pub const GraphicsLimits = struct {
    pane_bytes: usize = core.graphics.max_image_bytes_per_pane,
    global_bytes: usize = core.graphics.max_image_bytes_global,
    images_per_pane: usize = core.graphics.max_images_per_pane,
    placements_per_pane: usize = core.graphics.max_placements_per_pane,
    payload_bytes: usize = core.graphics.max_encoded_chunk_bytes,
    chunks_per_image: usize = core.graphics.max_chunks_per_image,

    pub fn validate(limits: GraphicsLimits) !void {
        if (limits.pane_bytes < 2 or limits.pane_bytes > core.graphics.max_image_bytes_per_pane or
            limits.global_bytes < limits.pane_bytes or limits.global_bytes > core.graphics.max_image_bytes_global or
            limits.images_per_pane < 2 or limits.images_per_pane > core.graphics.max_images_per_pane or
            limits.placements_per_pane < 2 or limits.placements_per_pane > core.graphics.max_placements_per_pane or
            limits.payload_bytes == 0 or limits.payload_bytes > core.graphics.max_encoded_chunk_bytes or
            limits.chunks_per_image == 0 or limits.chunks_per_image > core.graphics.max_chunks_per_image)
        {
            return error.InvalidGraphicsLimits;
        }
    }
};

/// Cross-thread lock shared by the runtime thread and pane actors. A parking
/// pthread mutex rather than a spin loop: a descheduled holder must not make
/// the other side burn a core, and the media-allocator call sites have no
/// `Io` for an `Io.Mutex`.
pub const ParkingMutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn lock(mutex: *ParkingMutex) void {
        const rc = std.c.pthread_mutex_lock(&mutex.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(mutex: *ParkingMutex) void {
        const rc = std.c.pthread_mutex_unlock(&mutex.inner);
        std.debug.assert(rc == .SUCCESS);
    }
};

pub const GraphicsBudget = struct {
    mutex: ParkingMutex = .{},
    limit: usize,
    used: usize = 0,

    pub fn init(limit: usize) GraphicsBudget {
        return .{ .limit = limit };
    }

    pub fn reserve(budget: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) bool {
        budget.mutex.lock();
        defer budget.mutex.unlock();
        const pane_next = std.math.add(usize, pane.used, bytes) catch return false;
        const global_next = std.math.add(usize, budget.used, bytes) catch return false;
        if (pane_next > pane.limit or global_next > budget.limit) {
            return false;
        }
        pane.used = pane_next;
        budget.used = global_next;
        return true;
    }

    pub fn release(budget: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) void {
        budget.mutex.lock();
        defer budget.mutex.unlock();
        std.debug.assert(bytes <= pane.used and bytes <= budget.used);
        pane.used -= bytes;
        budget.used -= bytes;
    }

    pub fn releaseAll(budget: *GraphicsBudget, pane: *PaneMediaAllocator) void {
        budget.mutex.lock();
        defer budget.mutex.unlock();
        std.debug.assert(pane.used <= budget.used);
        budget.used -= pane.used;
        pane.used = 0;
    }
};

/// Allocator used by VT stream effects and KGP. Charging allocations before
/// forwarding them to the child allocator makes compressed input, decoded
/// pixels, parser buffers and IPC transfer snapshots obey one hard budget.
pub const PaneMediaAllocator = struct {
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
};
