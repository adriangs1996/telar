//! Runtime-owned shared-memory objects that carry one pane image generation
//! to a local client.
//!
//! The media actor freezes a generation right after the emulator decoded it,
//! while the pixels are still hot, and parks the object here. The runtime
//! thread later hands the name to a client attachment without touching the
//! pixels again. Everything here is bounded: a few slots per pane, one object
//! per image generation, and every byte reserved against the pane budget
//! before the object exists.

const core = @import("telar-core");
const builtin = @import("builtin");
const std = @import("std");
const privatefile = @import("privatefile");
const Inode = privatefile.Inode;

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
pub fn freezeSharedPixels(pixels: []const u8) ?core.ShmName {
    if (comptime !shm_supported) {
        return null;
    }
    var nonce = shared_freeze_nonce.load(.monotonic);
    if (nonce == 0) {
        nonce = @as(u32, @bitCast(std.c.getpid())) | 1;
        shared_freeze_nonce.store(nonce, .monotonic);
    }
    const sequence = shared_freeze_sequence.fetchAdd(1, .monotonic);
    var text: [core.max_shm_name_bytes]u8 = undefined;
    const printed = std.fmt.bufPrint(&text, "/tlr{x:0>8}{x}", .{ nonce, sequence }) catch
        return null;
    const name = core.ShmName.init(printed) catch return null;
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
/// name is malformed; the frame then falls back to Ghostty's parser, which
/// unlinks what it opens.
///
/// ```zig
/// const child = mapChildObject(encoded_name, byte_len) orelse return false;
/// defer child.close();
/// ```
pub fn mapChildObject(encoded_name: []const u8, byte_len: usize) ?ChildObject {
    if (comptime !shm_supported) {
        return null;
    }

    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const name = decodeChildName(encoded_name, &buffer) orelse return null;
    const fd = std.c.shm_open(name, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) {
        return null;
    }

    defer _ = std.c.close(fd);
    const inode = Inode.fromDescriptor(fd) catch return null;
    if (inode.size < byte_len) {
        return null;
    }

    const pixels = std.posix.mmap(null, byte_len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0) catch
        return null;
    _ = std.c.shm_unlink(name);
    return .{ .pixels = pixels };
}

/// Consumes a child's shared object without reading it: a frame folded away
/// by a newer one. Ghostty would have opened and unlinked it; skipping that
/// would leave the object alive after its child, since the protocol leaves
/// the unlink to the terminal.
///
/// ```zig
/// shared_transfer.releaseChildObject(encoded_name);
/// ```
pub fn releaseChildObject(encoded_name: []const u8) void {
    if (comptime !shm_supported) {
        return;
    }

    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const name = decodeChildName(encoded_name, &buffer) orelse return;
    const fd = std.c.shm_open(name, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
    if (std.posix.errno(fd) != .SUCCESS) {
        return;
    }

    _ = std.c.shm_unlink(name);
    _ = std.c.close(fd);
}

/// Decodes a child's base64 shared-object name into `buffer`, or null when
/// it is empty, too long, not base64 or holds a NUL.
///
/// ```zig
/// var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
/// const name = decodeChildName(encoded_name, &buffer) orelse return false;
/// ```
pub fn decodeChildName(encoded_name: []const u8, buffer: *[std.fs.max_path_bytes + 1]u8) ?[:0]const u8 {
    const Decoder = std.base64.standard.Decoder;
    const name_len = Decoder.calcSizeForSlice(encoded_name) catch return null;
    if (name_len == 0 or name_len > std.fs.max_path_bytes) {
        return null;
    }

    Decoder.decode(buffer[0..name_len], encoded_name) catch return null;
    if (std.mem.indexOfScalar(u8, buffer[0..name_len], 0) != null) {
        return null;
    }

    buffer[name_len] = 0;
    return buffer[0..name_len :0];
}

fn decodeChildPath(encoded_path: []const u8, buffer: *[std.fs.max_path_bytes + 1]u8) ?[:0]const u8 {
    const path = decodeChildName(encoded_path, buffer) orelse return null;
    if (path[0] != '/') {
        return null;
    }

    return path;
}

/// Opens a child-named file the runtime is willing to read pixels from: an
/// absolute path, no symlink at the leaf, a regular file owned by this user,
/// at least `byte_len` long. Returns the descriptor or null.
fn openChildFile(encoded_path: []const u8, byte_len: usize) ?std.c.fd_t {
    const file = openChildRegular(encoded_path) orelse return null;
    if (file.size < byte_len) {
        file.close();
        return null;
    }

    return file.fd;
}

/// Opens a child-named regular file the runtime is willing to read: an
/// absolute path, no symlink at the leaf, owned by this user. The open never
/// blocks, so a FIFO or a device named by the child cannot stall the media
/// actor before the type check refuses it.
///
/// ```zig
/// const file = openChildRegular(encoded_path) orelse return false;
/// defer file.close();
/// ```
pub fn openChildRegular(encoded_path: []const u8) ?ChildFile {
    if (comptime !shm_supported) {
        return null;
    }

    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = decodeChildPath(encoded_path, &buffer) orelse return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) {
        return null;
    }

    const inode = Inode.fromDescriptor(fd) catch {
        _ = std.c.close(fd);
        return null;
    };
    if (inode.kind() != .regular or inode.owner != std.c.getuid()) {
        _ = std.c.close(fd);
        return null;
    }

    return .{ .fd = fd, .size = inode.size };
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
pub fn mapOwnObject(name: core.ShmName, byte_len: usize) ?[]align(std.heap.page_size_min) u8 {
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

const ChildFile = struct {
    /// A validated child file, open read-only until `close`.
    fd: std.c.fd_t,
    size: u64,

    pub fn close(self: ChildFile) void {
        _ = std.c.close(self.fd);
    }
};

const ChildObject = struct {
    /// A child's shared object mapped read-only for one copy out of it.
    pixels: []align(std.heap.page_size_min) u8,

    /// Unmaps the object; the name was already unlinked, as the protocol
    /// asks of whoever consumes a `t=s` transmission.
    pub fn close(self: ChildObject) void {
        std.posix.munmap(self.pixels);
    }
};
