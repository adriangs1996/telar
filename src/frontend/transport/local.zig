//! Frontend connection to a local telar runtime.

const std = @import("std");
const core = @import("telar-core");

pub fn connect(io: std.Io, path: []const u8) !core.transport.SocketChannel {
    _ = io;
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    var address: std.c.sockaddr.un = .{ .path = undefined };
    if (path.len >= address.path.len) return error.NameTooLong;

    const socket = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (socket < 0) return switch (std.posix.errno(socket)) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .ACCES, .PERM => error.PermissionDenied,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        else => error.SocketFailed,
    };
    errdefer _ = std.c.close(socket);

    @memset(&address.path, 0);
    std.mem.copyForwards(u8, address.path[0..path.len], path);

    while (true) {
        const result = std.c.connect(
            socket,
            @ptrCast(&address),
            @intCast(@sizeOf(std.c.sockaddr.un)),
        );
        switch (std.posix.errno(result)) {
            .SUCCESS => return .init(.{ .socket = .{
                .handle = socket,
                .address = .{ .ip4 = .loopback(0) },
            } }),
            .INTR => continue,
            .CONNREFUSED => return error.ConnectionRefused,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.PermissionDenied,
            .NOTDIR => return error.NotDir,
            .LOOP => return error.SymLinkLoop,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            else => return error.ConnectFailed,
        }
    }
}

test "a missing local runtime has a stable error" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/runtime.sock",
        .{directory_buffer[0..directory_len]},
    );
    try std.testing.expectError(
        error.FileNotFound,
        connect(io, path),
    );
}
