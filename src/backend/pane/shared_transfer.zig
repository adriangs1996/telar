//! Runtime-owned shared-memory objects that carry one pane image generation
//! to a local client.
//!
//! The media actor freezes a generation right after the emulator decoded it,
//! while the pixels are still hot, and parks the object here. The runtime
//! thread later hands the name to a client attachment without touching the
//! pixels again. Everything here is bounded: a few slots per pane, one object
//! per image generation, and every byte reserved against the pane budget
//! before the object exists.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("telar-core");
const pane_mod = @import("root.zig");

const Io = std.Io;
const PaneMediaAllocator = pane_mod.PaneMediaAllocator;

const shm_supported =
    builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.link_libc;

pub const shared_memory_supported = shm_supported;

/// Frozen frames a pane may hold for clients that have not adopted them yet.
/// terminal-browser drives one image per pane; a handful covers panes that
/// replace a few images per batch without letting quota pile up unseen.
pub const max_prepared = 4;

var shared_freeze_sequence = std.atomic.Value(u64).init(0);
var shared_freeze_nonce = std.atomic.Value(u32).init(0);

/// Seeds the unguessable part of every shared object name for this process.
///
/// ```zig
/// initSharedFreezeNonce(io);
/// ```
pub fn initSharedFreezeNonce(io: Io) void {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    shared_freeze_nonce.store(@as(u32, @bitCast(bytes)) | 1, .monotonic);
}

/// Copies one image into a fresh, never-reused POSIX shared-memory object and
/// returns its name, or null when the platform or the kernel refuses. The
/// caller owns the object: whoever consumes or discards the name unlinks it.
///
/// ```zig
/// const name = freezeSharedPixels(pixels) orelse return error.SharedMemoryUnavailable;
/// ```
pub fn freezeSharedPixels(pixels: []const u8) ?core.graphics.ShmName {
    if (comptime !shm_supported) return null;
    var nonce = shared_freeze_nonce.load(.monotonic);
    if (nonce == 0) {
        nonce = @as(u32, @bitCast(std.c.getpid())) | 1;
        shared_freeze_nonce.store(nonce, .monotonic);
    }
    const sequence = shared_freeze_sequence.fetchAdd(1, .monotonic);
    var text: [core.graphics.max_shm_name_bytes]u8 = undefined;
    const printed = std.fmt.bufPrint(&text, "/tlr{x:0>8}{x}", .{ nonce, sequence }) catch
        return null;
    const name = core.graphics.ShmName.init(printed) catch return null;
    const fd = std.c.shm_open(
        name.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    if (std.posix.errno(fd) != .SUCCESS) return null;
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(pixels.len)) != 0) {
        _ = std.c.shm_unlink(name.sliceZ());
        return null;
    }
    const map = std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    ) catch {
        _ = std.c.shm_unlink(name.sliceZ());
        return null;
    };
    defer std.posix.munmap(map);
    @memcpy(map[0..pixels.len], pixels);
    return name;
}

/// A child's shared object mapped read-only for one copy out of it.
pub const ChildObject = struct {
    pixels: []align(std.heap.page_size_min) u8,

    /// Unmaps the object; the name was already unlinked, as the protocol
    /// asks of whoever consumes a `t=s` transmission.
    pub fn close(object: ChildObject) void {
        std.posix.munmap(object.pixels);
    }
};

/// Opens, validates and maps a child's shared object by its base64 name,
/// then unlinks the name. Null when the object is missing, undersized, or the
/// name is malformed.
///
/// ```zig
/// const child = mapChildObject(encoded_name, byte_len) orelse return false;
/// defer child.close();
/// ```
pub fn mapChildObject(encoded_name: []const u8, byte_len: usize) ?ChildObject {
    if (comptime !shm_supported) return null;
    const Decoder = std.base64.standard.Decoder;
    const name_len = Decoder.calcSizeForSlice(encoded_name) catch return null;
    if (name_len == 0 or name_len > std.fs.max_path_bytes) return null;
    var name_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    Decoder.decode(name_buffer[0..name_len], encoded_name) catch return null;
    if (std.mem.indexOfScalar(u8, name_buffer[0..name_len], 0) != null) return null;
    name_buffer[name_len] = 0;
    const name: [:0]const u8 = name_buffer[0..name_len :0];
    const fd = std.c.shm_open(name, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) return null;
    defer _ = std.c.close(fd);
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0) return null;
    if (stat.size < 0 or @as(u64, @intCast(stat.size)) < byte_len) return null;
    const pixels = std.posix.mmap(null, byte_len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0) catch
        return null;
    _ = std.c.shm_unlink(name);
    return .{ .pixels = pixels };
}

/// Maps a runtime-owned object read-only for the life of an emulator image.
///
/// ```zig
/// const storage = mapOwnObject(name, byte_len) orelse return false;
/// ```
pub fn mapOwnObject(name: core.graphics.ShmName, byte_len: usize) ?[]align(std.heap.page_size_min) u8 {
    if (comptime !shm_supported) return null;
    const fd = std.c.shm_open(name.sliceZ(), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) return null;
    defer _ = std.c.close(fd);
    return std.posix.mmap(null, byte_len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0) catch null;
}

/// One frozen generation waiting for a client attachment to adopt it.
pub const PreparedTransfer = struct {
    metadata: core.graphics.Image,
    name: core.graphics.ShmName,
    /// Bytes reserved against the pane budget for the object's lifetime.
    reserved_len: usize,

    fn discard(transfer: PreparedTransfer, media: *PaneMediaAllocator) void {
        _ = std.c.shm_unlink(transfer.name.sliceZ());
        media.releaseManual(transfer.reserved_len);
    }
};

const FrozenGeneration = struct {
    image_id: u32,
    generation: u64,
};

/// Bounded parking space for frozen generations plus the memory of which
/// generation was frozen last per image, so an adopted frame is never frozen
/// twice and a replaced one is released the moment its successor lands.
///
/// Written only by the pane's media actor while it owns the media borrow and
/// read only by the runtime thread while the actor is idle; the completion
/// event that ends the borrow is the fence between them.
pub const PreparedTransfers = struct {
    items: [max_prepared]?PreparedTransfer = @splat(null),
    frozen: [core.graphics.max_images_per_pane]?FrozenGeneration = @splat(null),

    /// Whether `key` (or a newer generation of its image) was already frozen.
    ///
    /// ```zig
    /// if (prepared.covers(key)) continue;
    /// ```
    pub fn covers(prepared: *const PreparedTransfers, key: core.graphics.ImageKey) bool {
        for (prepared.frozen) |slot| {
            const frozen = slot orelse continue;
            if (frozen.image_id == key.image_id) return frozen.generation >= key.generation;
        }
        return false;
    }

    /// Parks one frozen generation. An older unadopted generation of the same
    /// image is released first. Returns false when no slot is free; the
    /// caller then discards the object itself.
    ///
    /// ```zig
    /// if (!prepared.put(transfer, media)) transfer.discard(media);
    /// ```
    pub fn put(prepared: *PreparedTransfers, transfer: PreparedTransfer, media: *PaneMediaAllocator) bool {
        const image_id = transfer.metadata.key.image_id;
        var free_slot: ?usize = null;
        for (&prepared.items, 0..) |*slot, index| {
            if (slot.*) |existing| {
                if (existing.metadata.key.image_id != image_id) continue;
                existing.discard(media);
                slot.* = null;
                free_slot = index;
                break;
            } else if (free_slot == null) {
                free_slot = index;
            }
        }
        const index = free_slot orelse return false;
        prepared.items[index] = transfer;
        prepared.rememberFrozen(transfer.metadata.key);
        return true;
    }

    /// Hands out the frozen generation for `key`, if any. Ownership of the
    /// object and its reservation moves to the caller.
    ///
    /// ```zig
    /// if (pane.prepared_transfers.take(key)) |frozen| adopt(frozen);
    /// ```
    pub fn take(prepared: *PreparedTransfers, key: core.graphics.ImageKey) ?PreparedTransfer {
        for (&prepared.items) |*slot| {
            const existing = slot.* orelse continue;
            if (!std.meta.eql(existing.metadata.key, key)) continue;
            slot.* = null;
            return existing;
        }
        return null;
    }

    /// Whether a frozen generation for `key` is parked here.
    pub fn holds(prepared: *const PreparedTransfers, key: core.graphics.ImageKey) bool {
        for (prepared.items) |slot| {
            const existing = slot orelse continue;
            if (std.meta.eql(existing.metadata.key, key)) return true;
        }
        return false;
    }

    /// Releases every parked object and reservation.
    ///
    /// ```zig
    /// pane.prepared_transfers.discardAll(&pane.media_allocator);
    /// ```
    pub fn discardAll(prepared: *PreparedTransfers, media: *PaneMediaAllocator) void {
        for (&prepared.items) |*slot| {
            const existing = slot.* orelse continue;
            existing.discard(media);
            slot.* = null;
        }
        prepared.frozen = @splat(null);
    }

    /// Releases the parked frame for `key`, if any.
    ///
    /// ```zig
    /// prepared.discard(key, media);
    /// ```
    pub fn discard(prepared: *PreparedTransfers, key: core.graphics.ImageKey, media: *PaneMediaAllocator) void {
        if (prepared.take(key)) |existing| existing.discard(media);
    }

    /// Forgets images the emulator no longer holds, releasing any parked
    /// object of theirs. `alive` answers whether an image id still exists.
    ///
    /// ```zig
    /// prepared.retain(storage, media);
    /// ```
    pub fn retain(prepared: *PreparedTransfers, alive: anytype, media: *PaneMediaAllocator) void {
        for (&prepared.items) |*slot| {
            const existing = slot.* orelse continue;
            if (alive.holds(existing.metadata.key)) continue;
            existing.discard(media);
            slot.* = null;
        }
        for (&prepared.frozen) |*slot| {
            const frozen = slot.* orelse continue;
            if (alive.holdsImage(frozen.image_id)) continue;
            slot.* = null;
        }
    }

    fn rememberFrozen(prepared: *PreparedTransfers, key: core.graphics.ImageKey) void {
        var free_slot: ?usize = null;
        for (&prepared.frozen, 0..) |*slot, index| {
            if (slot.*) |frozen| {
                if (frozen.image_id != key.image_id) continue;
                slot.* = .{ .image_id = key.image_id, .generation = key.generation };
                return;
            } else if (free_slot == null) {
                free_slot = index;
            }
        }
        if (free_slot) |index| {
            prepared.frozen[index] = .{ .image_id = key.image_id, .generation = key.generation };
        }
    }
};

const TestAlive = struct {
    keys: []const core.graphics.ImageKey,

    fn holds(alive: TestAlive, key: core.graphics.ImageKey) bool {
        for (alive.keys) |candidate| if (std.meta.eql(candidate, key)) return true;
        return false;
    }

    fn holdsImage(alive: TestAlive, image_id: u32) bool {
        for (alive.keys) |candidate| if (candidate.image_id == image_id) return true;
        return false;
    }
};

fn testTransfer(image_id: u32, generation: u64, pixels: []const u8) !PreparedTransfer {
    return .{
        .metadata = .{
            .key = .{ .image_id = image_id, .generation = generation },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = pixels.len,
        },
        .name = freezeSharedPixels(pixels) orelse return error.SharedMemoryUnavailable,
        .reserved_len = pixels.len,
    };
}

fn objectExists(name: core.graphics.ShmName) bool {
    const fd = std.c.shm_open(name.sliceZ(), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) return false;
    _ = std.c.close(fd);
    return true;
}

test "a newer generation replaces the parked object of its image" {
    if (comptime !shm_supported) return error.SkipZigTest;
    var budget = pane_mod.GraphicsBudget.init(1024);
    var media = PaneMediaAllocator.init(std.testing.allocator, &budget, 1024);
    var prepared: PreparedTransfers = .{};
    defer prepared.discardAll(&media);
    const pixels = [_]u8{ 1, 2, 3, 255 };

    const first = try testTransfer(7, 1, &pixels);
    try std.testing.expect(media.reserveManual(first.reserved_len));
    try std.testing.expect(prepared.put(first, &media));
    try std.testing.expect(prepared.covers(.{ .image_id = 7, .generation = 1 }));
    try std.testing.expect(!prepared.covers(.{ .image_id = 7, .generation = 2 }));

    const second = try testTransfer(7, 2, &pixels);
    try std.testing.expect(media.reserveManual(second.reserved_len));
    try std.testing.expect(prepared.put(second, &media));

    try std.testing.expect(!objectExists(first.name));
    try std.testing.expect(objectExists(second.name));
    try std.testing.expectEqual(pixels.len, media.used);
    try std.testing.expect(prepared.take(.{ .image_id = 7, .generation = 1 }) == null);
    const adopted = prepared.take(.{ .image_id = 7, .generation = 2 }) orelse return error.NotParked;
    try std.testing.expect(prepared.covers(.{ .image_id = 7, .generation = 2 }));
    _ = std.c.shm_unlink(adopted.name.sliceZ());
    media.releaseManual(adopted.reserved_len);
    try std.testing.expectEqual(@as(usize, 0), media.used);
}

test "parking is bounded and releases what the emulator dropped" {
    if (comptime !shm_supported) return error.SkipZigTest;
    var budget = pane_mod.GraphicsBudget.init(1024);
    var media = PaneMediaAllocator.init(std.testing.allocator, &budget, 1024);
    var prepared: PreparedTransfers = .{};
    defer prepared.discardAll(&media);
    const pixels = [_]u8{ 1, 2, 3, 255 };

    var names: [max_prepared + 1]core.graphics.ShmName = undefined;
    for (0..max_prepared + 1) |index| {
        const transfer = try testTransfer(@intCast(index + 1), 1, &pixels);
        names[index] = transfer.name;
        try std.testing.expect(media.reserveManual(transfer.reserved_len));
        if (index == max_prepared) {
            try std.testing.expect(!prepared.put(transfer, &media));
            transfer.discard(&media);
        } else {
            try std.testing.expect(prepared.put(transfer, &media));
        }
    }
    try std.testing.expectEqual(max_prepared * pixels.len, media.used);
    try std.testing.expect(!objectExists(names[max_prepared]));

    const survivors = [_]core.graphics.ImageKey{.{ .image_id = 2, .generation = 1 }};
    prepared.retain(TestAlive{ .keys = &survivors }, &media);
    try std.testing.expectEqual(pixels.len, media.used);
    try std.testing.expect(!objectExists(names[0]));
    try std.testing.expect(objectExists(names[1]));
    try std.testing.expect(!prepared.covers(.{ .image_id = 1, .generation = 1 }));
    try std.testing.expect(prepared.covers(.{ .image_id = 2, .generation = 1 }));
}
