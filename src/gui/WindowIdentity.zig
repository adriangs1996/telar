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
        const name = std.fmt.bufPrintZ(&name_storage, "{s}.gui-{d}.lock", .{ basename, slot }) catch return error.NameTooLong;
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
pub fn deinit(identity: *Identity, io: std.Io) void {
    if (identity.file) |file| {
        file.close(io);
        identity.file = null;
    }
}

fn inspect(fd: std.c.fd_t) !native.struct_stat {
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

test "native window identities survive reopening while concurrent windows stay distinct" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temp.dir.realPath(io, &directory);
    var endpoint_storage: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_storage, "{s}/runtime.sock", .{directory[0..length]});
    var first = try Identity.acquire(io, endpoint);
    defer first.deinit(io);
    var second = try Identity.acquire(io, endpoint);
    defer second.deinit(io);
    const first_value = first.value;
    try std.testing.expect(first.value != .invalid and second.value != .invalid);
    try std.testing.expect(first.value != second.value);
    try std.testing.expectEqual(@as(u8, 0), first.slot);
    try std.testing.expectEqual(@as(u8, 1), second.slot);
    const original = try inspect(first.file.?.handle);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, original.st_mode) & 0o7777);
    const flags = std.c.fcntl(first.file.?.handle, std.c.F.GETFD);
    try std.testing.expect(flags >= 0 and flags & std.c.FD_CLOEXEC != 0);
    first.deinit(io);
    var reopened = try Identity.acquire(io, endpoint);
    defer reopened.deinit(io);
    try std.testing.expectEqual(first_value, reopened.value);
    try std.testing.expectEqual(original.st_ino, (try inspect(reopened.file.?.handle)).st_ino);
}

test "native window leases are scoped to each runtime endpoint" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temp.dir.realPath(io, &directory);
    var first_storage: [std.fs.max_path_bytes]u8 = undefined;
    var second_storage: [std.fs.max_path_bytes]u8 = undefined;
    var first = try Identity.acquire(io, try std.fmt.bufPrint(&first_storage, "{s}/one.sock", .{directory[0..length]}));
    defer first.deinit(io);
    var second = try Identity.acquire(io, try std.fmt.bufPrint(&second_storage, "{s}/two.sock", .{directory[0..length]}));
    defer second.deinit(io);
    try std.testing.expectEqual(@as(u8, 0), first.slot);
    try std.testing.expectEqual(@as(u8, 0), second.slot);
    try std.testing.expect(first.value != second.value);
}

test "native window leases remain bounded and recover a released slot" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temp.dir.realPath(io, &directory);
    var endpoint_storage: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_storage, "{s}/runtime.sock", .{directory[0..length]});
    var identities: [max_windows]Identity = undefined;
    var acquired: usize = 0;
    defer for (identities[0..acquired]) |*identity| {
        identity.deinit(io);
    };

    for (&identities, 0..) |*identity, slot| {
        identity.* = try Identity.acquire(io, endpoint);
        acquired += 1;
        try std.testing.expectEqual(@as(u8, @intCast(slot)), identity.slot);
    }

    try std.testing.expectError(error.NoFreeWindowIdentity, Identity.acquire(io, endpoint));
    const released_value = identities[17].value;
    identities[17].deinit(io);
    var reopened = try Identity.acquire(io, endpoint);
    defer reopened.deinit(io);
    try std.testing.expectEqual(@as(u8, 17), reopened.slot);
    try std.testing.expectEqual(released_value, reopened.value);
}

test "native window leases reject symlinks hard links and public permissions" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temp.dir.realPath(io, &directory);
    var endpoint_storage: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_storage, "{s}/runtime.sock", .{directory[0..length]});
    const name = "runtime.sock.gui-0.lock";
    try temp.dir.symLink(io, "target", name, .{});
    try std.testing.expectError(error.UnsafeWindowIdentityFile, Identity.acquire(io, endpoint));
    try temp.dir.deleteFile(io, name);
    const source = try temp.dir.createFile(io, "target", .{ .permissions = .fromMode(0o600) });
    source.close(io);
    try temp.dir.hardLink("target", temp.dir, name, io, .{});
    try std.testing.expectError(error.UnsafeWindowIdentityFile, Identity.acquire(io, endpoint));
    try temp.dir.deleteFile(io, name);
    const public = try temp.dir.createFile(io, name, .{ .permissions = .fromMode(0o644) });
    try public.setPermissions(io, .fromMode(0o644));
    public.close(io);
    try std.testing.expectError(error.UnsafeWindowIdentityFile, Identity.acquire(io, endpoint));
}

test "native window leases reject writable directories and wrong owners" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temp.dir.realPath(io, &directory);
    var endpoint_storage: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_storage, "{s}/runtime.sock", .{directory[0..length]});
    const file: std.Io.File = .{ .handle = temp.dir.handle, .flags = .{ .nonblocking = false } };
    const original = try inspect(file.handle);
    try file.setPermissions(io, .fromMode(0o777));
    defer file.setPermissions(io, .fromMode(@intCast(original.st_mode & 0o7777))) catch {};
    try std.testing.expectError(error.UnsafeWindowIdentityDirectory, Identity.acquire(io, endpoint));
    var wrong_owner = original;
    wrong_owner.st_uid = std.c.geteuid() +% 1;
    try std.testing.expectError(error.WindowIdentityWrongOwner, validate(wrong_owner, .directory));
    try std.testing.expectError(error.RelativePath, Identity.acquire(io, "relative.sock"));
    try std.testing.expectError(error.InvalidEndpoint, Identity.acquire(io, "/tmp/bad\x00path"));
}
