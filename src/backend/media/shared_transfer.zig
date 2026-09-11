//! Runtime-owned shared-memory objects that carry one pane image generation
//! to a local client.
//!
//! The media actor freezes a generation right after the emulator decoded it,
//! while the pixels are still hot, and parks the object here. The runtime
//! thread later hands the name to a client attachment without touching the
//! pixels again. Everything here is bounded: a few slots per pane, one object
//! per image generation, and every byte reserved against the pane budget
//! before the object exists.

const builtin = @import("builtin");
const std = @import("std");
const ShmNameType = @import("telar-core").ShmName;
const max_shm_name_bytes_module = @import("telar-core").max_shm_name_bytes;
const ChildObject = @import("ChildObject.zig");
const PreparedTransfer = @import("PreparedTransfer.zig");
const GraphicsBudgetType = @import("GraphicsBudget.zig");
const PaneMediaAllocator = @import("PaneMediaAllocator.zig");
const PreparedTransfers = @import("PreparedTransfers.zig");
const ImageKeyType = @import("telar-core").ImageKey;
const TestAlive = @import("TestAlive.zig");

const native = @cImport({
    @cInclude("sys/stat.h");
});

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
pub fn initSharedFreezeNonce(io: std.Io) void {
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
pub fn freezeSharedPixels(pixels: []const u8) ?ShmNameType {
    if (comptime !shm_supported) {
        return null;
    }
    var nonce = shared_freeze_nonce.load(.monotonic);
    if (nonce == 0) {
        nonce = @as(u32, @bitCast(std.c.getpid())) | 1;
        shared_freeze_nonce.store(nonce, .monotonic);
    }
    const sequence = shared_freeze_sequence.fetchAdd(1, .monotonic);
    var text: [max_shm_name_bytes_module]u8 = undefined;
    const printed = std.fmt.bufPrint(&text, "/tlr{x:0>8}{x}", .{ nonce, sequence }) catch
        return null;
    const name = ShmNameType.init(printed) catch return null;
    const fd = std.c.shm_open(
        name.sliceZ(),
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    if (std.posix.errno(fd) != .SUCCESS) {
        return null;
    }
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

/// Opens, validates and maps a child's shared object by its base64 name,
/// then unlinks the name. Null when the object is missing, undersized, or the
/// name is malformed.
///
/// ```zig
/// const child = mapChildObject(encoded_name, byte_len) orelse return false;
/// defer child.close();
/// ```
pub fn mapChildObject(encoded_name: []const u8, byte_len: usize) ?ChildObject {
    if (comptime !shm_supported) {
        return null;
    }
    const Decoder = std.base64.standard.Decoder;
    const name_len = Decoder.calcSizeForSlice(encoded_name) catch return null;
    if (name_len == 0 or name_len > std.fs.max_path_bytes) {
        return null;
    }
    var name_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    Decoder.decode(name_buffer[0..name_len], encoded_name) catch return null;
    if (std.mem.indexOfScalar(u8, name_buffer[0..name_len], 0) != null) {
        return null;
    }
    name_buffer[name_len] = 0;
    const name: [:0]const u8 = name_buffer[0..name_len :0];
    const fd = std.c.shm_open(name, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) {
        return null;
    }
    defer _ = std.c.close(fd);
    var stat: native.struct_stat = undefined;
    if (native.fstat(fd, &stat) != 0) {
        return null;
    }

    if (stat.st_size < 0 or @as(u64, @intCast(stat.st_size)) < byte_len) {
        return null;
    }
    const pixels = std.posix.mmap(null, byte_len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0) catch
        return null;
    _ = std.c.shm_unlink(name);
    return .{ .pixels = pixels };
}

fn decodeChildPath(encoded_path: []const u8, buffer: *[std.fs.max_path_bytes + 1]u8) ?[:0]const u8 {
    const Decoder = std.base64.standard.Decoder;
    const path_len = Decoder.calcSizeForSlice(encoded_path) catch return null;
    if (path_len == 0 or path_len > std.fs.max_path_bytes) {
        return null;
    }
    Decoder.decode(buffer[0..path_len], encoded_path) catch return null;
    if (std.mem.indexOfScalar(u8, buffer[0..path_len], 0) != null) {
        return null;
    }
    if (buffer[0] != '/') {
        return null;
    }
    buffer[path_len] = 0;
    return buffer[0..path_len :0];
}

/// Opens a child-named file the runtime is willing to read pixels from: an
/// absolute path, no symlink at the leaf, a regular file owned by this user,
/// at least `byte_len` long. Returns the descriptor or null.
fn openChildFile(encoded_path: []const u8, byte_len: usize) ?std.c.fd_t {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = decodeChildPath(encoded_path, &buffer) orelse return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) {
        return null;
    }
    var stat: native.struct_stat = undefined;
    const acceptable = native.fstat(fd, &stat) == 0 and
        std.c.S.ISREG(@intCast(stat.st_mode)) and
        stat.st_uid == std.c.getuid() and
        stat.st_size >= 0 and @as(u64, @intCast(stat.st_size)) >= byte_len;
    if (!acceptable) {
        _ = std.c.close(fd);
        return null;
    }
    return fd;
}

/// Whether a child's file passes every check `mapChildFile` applies.
///
/// ```zig
/// const accepted = validateChildFile(encoded_path, 4);
/// ```
pub fn validateChildFile(encoded_path: []const u8, byte_len: usize) bool {
    if (comptime !shm_supported) {
        return false;
    }
    const fd = openChildFile(encoded_path, byte_len) orelse return false;
    _ = std.c.close(fd);
    return true;
}

/// Maps a validated child file read-only for one copy out of it. The file
/// is never written, deleted or kept open.
///
/// ```zig
/// const child = mapChildFile(encoded_path, byte_len) orelse return false;
/// defer child.close();
/// ```
pub fn mapChildFile(encoded_path: []const u8, byte_len: usize) ?ChildObject {
    if (comptime !shm_supported) {
        return null;
    }
    const fd = openChildFile(encoded_path, byte_len) orelse return null;
    defer _ = std.c.close(fd);
    const pixels = std.posix.mmap(null, byte_len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0) catch
        return null;
    return .{ .pixels = pixels };
}

/// Maps a runtime-owned object read-only for the life of an emulator image.
///
/// ```zig
/// const storage = mapOwnObject(name, byte_len) orelse return false;
/// ```
pub fn mapOwnObject(name: ShmNameType, byte_len: usize) ?[]align(std.heap.page_size_min) u8 {
    if (comptime !shm_supported) {
        return null;
    }
    const fd = std.c.shm_open(name.sliceZ(), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) {
        return null;
    }
    defer _ = std.c.close(fd);
    return std.posix.mmap(null, byte_len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0) catch null;
}

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

fn objectExists(name: ShmNameType) bool {
    const fd = std.c.shm_open(name.sliceZ(), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) {
        return false;
    }
    _ = std.c.close(fd);
    return true;
}

test "child file metadata rejects undersized files, directories, symlinks and missing paths" {
    if (comptime !shm_supported) {
        return error.SkipZigTest;
    }

    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "pixels", .data = "RGBA" });
    try temp.dir.createDir(io, "directory", std.Io.File.Permissions.fromMode(0o700));
    try temp.dir.symLink(io, "pixels", "alias", .{});
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);

    for ([_][]const u8{ "pixels", "directory", "alias", "missing" }, 0..) |leaf, index| {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory_buffer[0..directory_len], leaf });
        var encoded_buffer: [std.base64.standard.Encoder.calcSize(std.fs.max_path_bytes)]u8 = undefined;
        const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, path);

        try std.testing.expectEqual(index == 0, validateChildFile(encoded, 4));
        try std.testing.expect(!validateChildFile(encoded, 5));
    }
}

test "child shared memory validates size before mapping and unlinking" {
    if (comptime !shm_supported) {
        return error.SkipZigTest;
    }

    const name = freezeSharedPixels("RGBA") orelse return error.SharedMemoryUnavailable;
    defer _ = std.c.shm_unlink(name.sliceZ());
    var encoded_buffer: [std.base64.standard.Encoder.calcSize(std.fs.max_path_bytes)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, name.sliceZ());

    // Darwin reports shared-memory sizes rounded up to the host page size.
    const oversized = mapChildObject(encoded, std.heap.pageSize() + 1);
    defer {
        if (oversized) |object| {
            object.close();
        }
    }

    try std.testing.expectEqual(@as(?ChildObject, null), oversized);
    try std.testing.expect(objectExists(name));
    const mapped = mapChildObject(encoded, 4) orelse return error.SharedMemoryUnavailable;
    defer mapped.close();

    try std.testing.expectEqualStrings("RGBA", mapped.pixels);
    try std.testing.expect(!objectExists(name));
}

test "a newer generation replaces the parked object of its image" {
    if (comptime !shm_supported) {
        return error.SkipZigTest;
    }
    var budget = GraphicsBudgetType.init(1024);
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
    if (comptime !shm_supported) {
        return error.SkipZigTest;
    }
    var budget = GraphicsBudgetType.init(1024);
    var media = PaneMediaAllocator.init(std.testing.allocator, &budget, 1024);
    var prepared: PreparedTransfers = .{};
    defer prepared.discardAll(&media);
    const pixels = [_]u8{ 1, 2, 3, 255 };

    var names: [max_prepared + 1]ShmNameType = undefined;
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

    const survivors = [_]ImageKeyType{.{ .image_id = 2, .generation = 1 }};
    prepared.retain(TestAlive{ .keys = &survivors }, &media);
    try std.testing.expectEqual(pixels.len, media.used);
    try std.testing.expect(!objectExists(names[0]));
    try std.testing.expect(objectExists(names[1]));
    try std.testing.expect(!prepared.covers(.{ .image_id = 1, .generation = 1 }));
    try std.testing.expect(prepared.covers(.{ .image_id = 2, .generation = 1 }));
}
