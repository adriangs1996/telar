const std = @import("std");
const core = @import("telar-core");
const limit_reached = @import("limit_reached.zig");
const privatefile = @import("privatefile");
const FileOptions = @import("arguments/FileOptions.zig");
const max_bytes = 128 * 1024 * 1024;
const bytes_limit = core.Limit.declare("file_transfer.max_bytes", "bytes", max_bytes);

/// Transfers a single bounded file through raw stdin/stdout. Example: `return file_transfer.run(init, options);`.
pub fn run(init: std.process.Init, options: FileOptions) u8 {
    transfer(init, options) catch |err| {
        std.debug.print("telar file: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn transfer(init: std.process.Init, options: FileOptions) !void {
    if (options.bytes) |size| {
        if (size > max_bytes) {
            limit_reached.report(.{ .limit = bytes_limit, .requested = size });
            return error.FileTransferLimit;
        }
    }

    var parent = try openParent(init.io, options.path);
    defer parent.close(init.io);
    const name = std.fs.path.basename(options.path);
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.InvalidFilePath;
    }

    if (options.action == .get) {
        const file = try openRegular(parent, name);
        defer file.close(init.io);
        const inode = try privatefile.Inode.fromDescriptor(file.handle);
        if (inode.kind() != .regular or inode.owner != std.c.getuid() or inode.links != 1) {
            return error.UnsafeTransferFile;
        }

        if (inode.size > max_bytes) {
            limit_reached.report(.{ .limit = bytes_limit, .requested = inode.size });
            return error.FileTransferLimit;
        }

        _ = try copy(init.io, file, std.Io.File.stdout());
        return;
    }

    var nonce: [16]u8 = undefined;
    try init.io.randomSecure(&nonce);
    var name_buffer: [64]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&name_buffer, ".telar-file-{s}", .{&std.fmt.bytesToHex(nonce, .lower)});
    const file = try parent.createFile(init.io, temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(init.io);
    defer parent.deleteFile(init.io, temporary) catch {};
    const size = try copy(init.io, std.Io.File.stdin(), file);
    if (size != options.bytes.?) {
        return error.FileTransferInterrupted;
    }

    try file.sync(init.io);
    try std.Io.Dir.renamePreserve(parent, temporary, parent, name, init.io);
    var buffer: [128]u8 = undefined;
    const result = try std.fmt.bufPrint(&buffer, "{{\"bytes\":{d},\"published\":true}}\n", .{size});
    try std.Io.File.stdout().writeStreamingAll(init.io, result);
}

fn copy(io: std.Io, input: std.Io.File, output: std.Io.File) !u64 {
    var buffer: [64 * 1024]u8 = undefined;
    var reader = input.readerStreaming(io, &.{});
    var total: u64 = 0;
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) {
            return total;
        }

        total += count;
        if (total > max_bytes) {
            limit_reached.report(.{ .limit = bytes_limit, .requested = total });
            return error.FileTransferLimit;
        }

        try output.writeStreamingAll(io, buffer[0..count]);
    }
}

/// Opens an explicit canonical parent without following any symlink and checks ownership.
/// Example: `var directory = try file_transfer.openParent(io, "/home/user/work/brief.md");`.
pub fn openParent(io: std.Io, path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) {
        return error.AbsoluteFilePathRequired;
    }

    const parent = std.fs.path.dirname(path) orelse return error.InvalidFilePath;
    return openDirectory(io, parent, false);
}

/// Opens or creates an owned directory without following symlinks. Example: `var dir = try file_transfer.openDirectory(io, root, true);`.
pub fn openDirectory(io: std.Io, path: []const u8, create: bool) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) {
        return error.AbsoluteFilePathRequired;
    }

    var current = try std.Io.Dir.openDirAbsolute(io, "/", .{});
    errdefer current.close(io);
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidFilePath;
        }

        const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound or !create) {
                return err;
            }

            current.createDir(io, component, .fromMode(0o700)) catch |creation| {
                if (creation != error.PathAlreadyExists) {
                    return creation;
                }
            };
            break :blk try current.openDir(io, component, .{ .follow_symlinks = false });
        };
        current.close(io);
        current = next;
    }

    const inode = try privatefile.Inode.fromDescriptor(current.handle);
    if (inode.owner != std.c.getuid() or inode.mode & 0o022 != 0) {
        return error.UnsafeTransferDirectory;
    }

    return current;
}

/// Opens without blocking on devices/FIFOs, then validates the descriptor.
/// Example: `const file = try file_transfer.openRegular(directory, "brief.md");`.
pub fn openRegular(parent: std.Io.Dir, name: []const u8) !std.Io.File {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
    const options: std.c.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true };
    const fd = std.c.openat(parent.handle, name_z, options);
    if (fd < 0) {
        return if (std.posix.errno(fd) == .NOENT) error.FileNotFound else error.UnsafeTransferFile;
    }

    errdefer _ = std.c.close(fd);
    const inode = try privatefile.Inode.fromDescriptor(fd);
    if (inode.kind() != .regular or inode.owner != std.c.getuid() or inode.links != 1) {
        return error.UnsafeTransferFile;
    }

    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}
