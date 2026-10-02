const builtin = @import("builtin");
const std = @import("std");
const listener_support = @import("listener_support.zig");
const Listener = @This();

const PortSet = listener_support.PortSet;
/// Whether `socket` takes `SOCK_CLOEXEC`; Darwin sets it with `fcntl`.
const atomic_cloexec = !builtin.os.tag.isDarwin();
/// Whether every listener sets `SO_REUSEADDR`. Linux never lets that option
/// bind over a socket listening on the port, wildcard included, and a
/// TIME_WAIT connection only yields to a bind when the listener that
/// accepted it set the option too.
const reuse_always = builtin.os.tag == .linux;
/// How long the probe of a refused port waits for an answer. A loopback
/// handshake completes in microseconds; a port bound without a listener, or
/// one whose backlog is full, never answers, and waiting for the kernel's
/// own connect timeout would stall the start for seconds.
const probe_timeout_ms = 50;

/// How a listening socket shares its port with sockets already on it.
const Sharing = enum {
    /// Fail on any other socket, TIME_WAIT connections included.
    exclusive,
    /// Allow connections this port closed and left in TIME_WAIT.
    reuse_closed,
};

/// What a bind does with a port only TIME_WAIT connections may hold.
const Closed = enum {
    /// Probe it, and bind it when nothing answers: the preferred port.
    reclaim,
    /// Skip it: a port of the scan.
    skip,
};

server: std.Io.net.Server,
bound_port: u16,
/// Whether the listening socket is still open and holds its port.
listening: bool = true,

/// Binds the preferred loopback port when one is given and free, else the
/// first available port in Telar's bounded proxy range that no other runtime
/// remembers, else the first available one at all. Ports already owned by
/// another process are skipped; exhaustion is reported as
/// `error.ProxyPortUnavailable`.
///
/// ```zig
/// var listener = try Listener.bind(io, preferred_port, &reserved_ports);
/// defer listener.deinit(io);
/// ```
pub fn bind(io: std.Io, preferred: ?u16, reserved: *const PortSet) !Listener {
    if (preferred) |port_value| {
        if (try bindPort(io, port_value, .reclaim)) |bound| {
            return bound;
        }
    }

    const unreserved = reserved.complement();
    if (try bindFirst(io, &unreserved)) |bound| {
        return bound;
    }

    if (try bindFirst(io, reserved)) |bound| {
        return bound;
    }

    return error.ProxyPortUnavailable;
}

fn bindFirst(io: std.Io, candidates: *const PortSet) !?Listener {
    var offsets = candidates.iterator(.{});
    while (offsets.next()) |offset| {
        if (try bindPort(io, listener_support.first_port + @as(u16, @intCast(offset)), .skip)) |bound| {
            return bound;
        }
    }

    return null;
}

/// Listens on the loopback `port_value`, or returns null when another socket
/// holds it. The connections the proxy closed at its last stop linger in
/// TIME_WAIT on this port for up to a minute, and a plain bind refuses the
/// port meanwhile, so a quick restart would lose the port children
/// inherited.
///
/// Linux sets `SO_REUSEADDR` on every listener, which is enough there. BSD
/// binds plainly first: its `SO_REUSEADDR` also lets a loopback socket shadow
/// another process listening on every address, so it reuses a refused port
/// only when `closed` asks for it and a bounded probe finds nobody accepting
/// connections there. `SO_REUSEPORT` is never set. Windows keeps the plain
/// bind: its `SO_REUSEADDR` takes ports in use.
fn bindPort(io: std.Io, port_value: u16, closed: Closed) !?Listener {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port_value) catch unreachable;
    if (builtin.os.tag == .windows) {
        const server = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => return null,
            else => |other| return other,
        };

        return .{ .server = server, .bound_port = port_value };
    }

    const first_sharing: Sharing = if (reuse_always) .reuse_closed else .exclusive;
    const handle = try listenLoopback(address, first_sharing) orelse block: {
        if (reuse_always or closed == .skip or answers(address)) {
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

/// Whether some process may accept connections on `address`: true unless the
/// connection is refused within `probe_timeout_ms`. Any other outcome,
/// silence included, counts as an answer, so the port stays another's.
fn answers(address: std.Io.net.IpAddress) bool {
    const handle = openSocket() catch return true;
    defer _ = std.c.close(handle);

    const flags = std.c.fcntl(handle, std.c.F.GETFL);
    if (flags < 0) {
        return true;
    }

    var nonblocking: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    nonblocking.NONBLOCK = true;
    if (std.c.fcntl(handle, std.c.F.SETFL, @as(c_int, @bitCast(nonblocking))) != 0) {
        return true;
    }

    const loopback = socketAddress(address);
    if (std.c.connect(handle, @ptrCast(&loopback), @sizeOf(std.c.sockaddr.in)) == 0) {
        return true;
    }

    switch (std.posix.errno(-1)) {
        .CONNREFUSED => return false,
        .INPROGRESS => {},
        else => return true,
    }

    var pending = [_]std.c.pollfd{.{
        .fd = handle,
        .events = std.c.POLL.OUT,
        .revents = 0,
    }};
    if (std.c.poll(&pending, pending.len, probe_timeout_ms) != pending.len) {
        return true;
    }

    var failure: c_int = 0;
    var failure_len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(handle, std.c.SOL.SOCKET, std.c.SO.ERROR, &failure, &failure_len) != 0) {
        return true;
    }

    return failure != @intFromEnum(std.posix.E.CONNREFUSED);
}

fn openSocket() !std.c.fd_t {
    const cloexec: u32 = if (atomic_cloexec) std.c.SOCK.CLOEXEC else 0;
    const handle = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM | cloexec, 0);
    if (handle < 0) {
        return error.ProxySocketUnavailable;
    }
    errdefer _ = std.c.close(handle);

    if (!atomic_cloexec and std.c.fcntl(handle, std.c.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) != 0) {
        return error.ProxySocketUnavailable;
    }

    return handle;
}

fn socketAddress(address: std.Io.net.IpAddress) std.c.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, address.ip4.port),
        .addr = @bitCast(address.ip4.bytes),
    };
}

fn listenLoopback(address: std.Io.net.IpAddress, sharing: Sharing) !?std.c.fd_t {
    const handle = try openSocket();
    errdefer _ = std.c.close(handle);

    if (sharing == .reuse_closed) {
        const enabled: c_int = 1;
        if (std.c.setsockopt(handle, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &enabled, @sizeOf(c_int)) != 0) {
            return error.ProxySocketUnavailable;
        }
    }

    const loopback = socketAddress(address);
    if (std.c.bind(handle, @ptrCast(&loopback), @sizeOf(std.c.sockaddr.in)) != 0) {
        return switch (std.posix.errno(-1)) {
            .ADDRINUSE => closedSocket(handle),
            else => error.ProxySocketUnavailable,
        };
    }

    if (std.c.listen(handle, std.Io.net.default_kernel_backlog) != 0) {
        return switch (std.posix.errno(-1)) {
            .ADDRINUSE => closedSocket(handle),
            else => error.ProxySocketUnavailable,
        };
    }

    return handle;
}

fn closedSocket(handle: std.c.fd_t) ?std.c.fd_t {
    _ = std.c.close(handle);
    return null;
}

/// Closes the owned listening socket, which frees its port for the next
/// listener. Closing again does nothing; `port` keeps answering.
///
/// ```zig
/// listener.deinit(io);
/// ```
pub fn deinit(self: *Listener, io: std.Io) void {
    if (!self.listening) {
        return;
    }

    self.server.deinit(io);
    self.listening = false;
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
