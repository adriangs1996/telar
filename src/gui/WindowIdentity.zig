//! A persistent window slot with an exclusive kernel lease. Reopening a slot
//! restores its client layout; another live window must choose a different one.
const std = @import("std");
const core = @import("telar-core");
const native = @cImport({
    @cInclude("sys/stat.h");
});
const Identity = @This();

pub const max_windows = 64;
file: ?std.Io.File,
value: core.ClientIdentity,
slot: u8,

/// Acquires the first free slot in the runtime's trusted endpoint directory.
/// Files are never unlinked: replacing a locked inode would split its lease.
/// Example: `var identity = try WindowIdentity.acquire(io, endpoint);`
pub fn acquire(io: std.Io, endpoint: []const u8) !Identity {
    if (!std.fs.path.isAbsolute(endpoint)) {
        return error.RelativePath;
    }

    if (std.mem.indexOfScalar(u8, endpoint, 0) != null) {
        return error.InvalidEndpoint;
    }

    const parent = std.fs.path.dirname(endpoint) orelse return error.InvalidEndpoint;
    const basename = std.fs.path.basename(endpoint);
    if (basename.len == 0) {
        return error.InvalidEndpoint;
    }

    var directory = try std.Io.Dir.openDirAbsolute(io, parent, .{ .follow_symlinks = false });
    defer directory.close(io);
    try validate(try inspect(directory.handle), .directory);
    var canonical_storage: [std.fs.max_path_bytes]u8 = undefined;
    const canonical_len = try directory.realPath(io, &canonical_storage);
    var namespace = std.crypto.hash.sha2.Sha256.init(.{});
    namespace.update("telar-gui-window-v1\x00");
    namespace.update(canonical_storage[0..canonical_len]);
    namespace.update("/");
    namespace.update(basename);
    namespace.update("\x00");

    for (0..max_windows) |slot| {
        var name_storage: [std.fs.max_name_bytes]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_storage, "{s}.gui-{d}.lock", .{ basename, slot }) catch return error.LockNameTooLong;
        const fd = std.c.openat(directory.handle, name, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) {
            return switch (std.posix.errno(fd)) {
                .LOOP, .ISDIR => error.UnsafeWindowIdentityFile,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .ACCES, .PERM => error.PermissionDenied,
                else => error.WindowIdentityOpenFailed,
            };
        }

        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        var retained = false;
        defer if (!retained) {
            file.close(io);
        };
        try validate(try inspect(fd), .regular);
        if (!try file.tryLock(io, .exclusive)) {
            continue;
        }

        var hash = namespace;
        hash.update(&.{@intCast(slot)});
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hash.final(&digest);
        retained = true;
        return .{ .file = file, .value = @enumFromInt(std.mem.readInt(u64, digest[0..8], .little) | 1), .slot = @intCast(slot) };
    }

    return error.NoFreeWindowIdentity;
}

/// Releases the lease after the native application and its consumers stop.
/// Example: `defer identity.deinit(io);`
pub fn deinit(self: *Identity, io: std.Io) void {
    if (self.file) |file| {
        file.close(io);
        self.file = null;
    }
}

fn inspect(fd: std.c.fd_t) !native.struct_stat {
    // SAFETY: fstat fills stat on success; failure returns an error before the value is returned.
    var stat: native.struct_stat = undefined;
    if (native.fstat(fd, &stat) != 0) {
        return error.WindowIdentityStatFailed;
    }

    return stat;
}

fn validate(stat: native.struct_stat, kind: enum { directory, regular }) !void {
    if (stat.st_uid != std.c.geteuid()) {
        return error.WindowIdentityWrongOwner;
    }

    if (kind == .directory) {
        if (stat.st_mode & native.S_IFMT != native.S_IFDIR or stat.st_mode & 0o022 != 0) {
            return error.UnsafeWindowIdentityDirectory;
        }
    } else if (stat.st_mode & native.S_IFMT != native.S_IFREG or stat.st_nlink != 1 or stat.st_mode & 0o7777 != 0o600) {
        return error.UnsafeWindowIdentityFile;
    }
}
