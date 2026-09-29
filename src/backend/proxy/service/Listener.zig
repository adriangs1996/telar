const builtin = @import("builtin");
const std = @import("std");
const listener_support = @import("listener_support.zig");
const Listener = @This();

/// Whether `socket` takes `SOCK_CLOEXEC`; Darwin sets it with `fcntl`.
const atomic_cloexec = !builtin.os.tag.isDarwin();

/// How a listening socket shares its port with sockets already on it.
const Sharing = enum {
    /// Fail on any other socket, TIME_WAIT connections included.
    exclusive,
    /// Allow connections this port closed and left in TIME_WAIT.
    reuse_closed,
};

server: std.Io.net.Server,
bound_port: u16,

/// Binds the preferred loopback port when one is given and free, else the
/// first available port in Telar's bounded proxy range. Ports already owned
/// by another process are skipped; exhaustion is reported as
/// `error.ProxyPortUnavailable`.
///
/// ```zig
/// var listener = try Listener.bind(io, preferred_port);
/// defer listener.deinit(io);
/// ```
pub fn bind(io: std.Io, preferred: ?u16) !Listener {
    if (preferred) |port_value| {
        if (try bindPort(io, port_value)) |bound| {
            return bound;
        }
    }

    var candidate_port = listener_support.first_port;
    while (candidate_port < listener_support.first_port + listener_support.port_attempts) : (candidate_port += 1) {
        if (try bindPort(io, candidate_port)) |bound| {
            return bound;
        }
    }

    return error.ProxyPortUnavailable;
}

/// Listens on the loopback `port_value`, or returns null when another socket
/// listens there. The connections the proxy closed at its last stop linger
/// in TIME_WAIT on this port for up to a minute, and a plain bind refuses the
/// port meanwhile, so a quick restart would lose the port children
/// inherited. When a plain bind fails and nothing answers a connection on
/// the port, POSIX binds again with `SO_REUSEADDR`. The probe comes first
/// because on BSD that option also lets a loopback socket shadow another
/// process listening on every address. `SO_REUSEPORT` is never set, and
/// Windows keeps the plain bind: its `SO_REUSEADDR` takes ports in use.
fn bindPort(io: std.Io, port_value: u16) !?Listener {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port_value) catch unreachable;
    if (builtin.os.tag == .windows) {
        const server = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => return null,
            else => |other| return other,
        };

        return .{ .server = server, .bound_port = port_value };
    }

    const handle = try listenLoopback(address, .exclusive) orelse block: {
        if (answers(io, address)) {
            return null;
        }

        break :block try listenLoopback(address, .reuse_closed) orelse return null;
    };

    return .{
        .server = .{
            .socket = .{
                .handle = handle,
                .address = address,
            },
            .options = {},
        },
        .bound_port = port_value,
    };
}

/// Whether some process accepts connections on `address`.
fn answers(io: std.Io, address: std.Io.net.IpAddress) bool {
    const stream = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.ConnectionRefused => return false,
        else => return true,
    };

    stream.close(io);
    return true;
}

fn listenLoopback(address: std.Io.net.IpAddress, sharing: Sharing) !?std.c.fd_t {
    const cloexec: u32 = if (atomic_cloexec) std.c.SOCK.CLOEXEC else 0;
    const handle = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM | cloexec, 0);
    if (handle < 0) {
        return error.ProxySocketUnavailable;
    }
    errdefer _ = std.c.close(handle);

    if (!atomic_cloexec and std.c.fcntl(handle, std.c.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) != 0) {
        return error.ProxySocketUnavailable;
    }

    if (sharing == .reuse_closed) {
        const enabled: c_int = 1;
        if (std.c.setsockopt(handle, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &enabled, @sizeOf(c_int)) != 0) {
            return error.ProxySocketUnavailable;
        }
    }

    const loopback: std.c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, address.ip4.port),
        .addr = @bitCast(address.ip4.bytes),
    };
    if (std.c.bind(handle, @ptrCast(&loopback), @sizeOf(std.c.sockaddr.in)) != 0) {
        return switch (std.posix.errno(-1)) {
            .ADDRINUSE => closed(handle),
            else => error.ProxySocketUnavailable,
        };
    }

    if (std.c.listen(handle, std.Io.net.default_kernel_backlog) != 0) {
        return switch (std.posix.errno(-1)) {
            .ADDRINUSE => closed(handle),
            else => error.ProxySocketUnavailable,
        };
    }

    return handle;
}

fn closed(handle: std.c.fd_t) ?std.c.fd_t {
    _ = std.c.close(handle);
    return null;
}

/// Closes the owned listening socket.
///
/// ```zig
/// listener.deinit(io);
/// ```
pub fn deinit(self: *Listener, io: std.Io) void {
    self.server.deinit(io);
}

/// Waits for one incoming loopback connection.
///
/// ```zig
/// const stream = try listener.accept(io);
/// ```
pub fn accept(self: *Listener, io: std.Io) !std.Io.net.Stream {
    return self.server.accept(io);
}

/// Returns the port selected during `bind`.
///
/// ```zig
/// const port = listener.port();
/// ```
pub fn port(self: *const Listener) u16 {
    return self.bound_port;
}
