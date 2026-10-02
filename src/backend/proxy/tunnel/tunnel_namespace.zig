//! One authenticated CONNECT tunnel from request head through protocol relay.

const builtin = @import("builtin");
const Counters = @import("../Counters.zig");
const Exchange = @import("Exchange.zig");
const connect_authentication = @import("../connect_authentication.zig");
const name_resolution = @import("../name_resolution.zig");
const Resolutions = @import("../Resolutions.zig");
const std = @import("std");
const Snapshot = @import("../Snapshot.zig");

pub fn recordAuthenticationRejection(telemetry: *Counters, rejection: connect_authentication.RejectionMetric) void {
    telemetry.record(.rejected_connection);

    switch (rejection) {
        .invalid_authorization => telemetry.record(.invalid_authorization_rejection),
        .unknown_credential => telemetry.record(.unknown_credential_rejection),
    }
}

/// Relays opaque bytes both ways until both sides close; every copy marks
/// the connection active. Once one side ends, the connection is half
/// closed, and the service closes it when the other goes silent.
///
/// ```zig
/// tunnel_namespace.relayPassthrough(child, origin, &exchange);
/// ```
pub fn relayPassthrough(child: std.Io.net.Stream, origin: std.Io.net.Stream, exchange: *Exchange) void {
    const io = exchange.io;
    var outbound = io.concurrent(pumpPassthrough, .{ child, origin, exchange }) catch return;
    pumpPassthrough(origin, child, exchange);
    outbound.await(io);
}

fn pumpPassthrough(source: std.Io.net.Stream, destination: std.Io.net.Stream, exchange: *Exchange) void {
    const io = exchange.io;
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var reader = source.reader(io, &read_buffer);
    var writer = destination.writer(io, &write_buffer);

    while (true) {
        const copied = reader.interface.stream(&writer.interface, .unlimited) catch break;
        writer.interface.flush() catch break;

        if (copied == 0) {
            break;
        }

        exchange.touch();
    }

    exchange.enter(.half_closed);
    destination.shutdown(io, .send) catch {};
}

/// Reads one CONNECT head into `buffer`: its length, the end of the
/// stream, or a head past the buffer, which the caller answers with 431.
///
/// ```zig
/// switch (tunnel_namespace.readConnectHead(io, stream, &head)) { ... }
/// ```
pub fn readConnectHead(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) ConnectHead {
    var read_buffer: [connect_read_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buffer);
    var reader = stream.reader(io, &read_buffer);
    var len: usize = 0;

    while (len < buffer.len) {
        const byte = reader.interface.takeByte() catch return .ended;
        buffer[len] = byte;
        len += 1;

        if (len >= 4 and std.mem.eql(u8, buffer[len - 4 .. len], "\r\n\r\n")) {
            return .{
                .complete = len,
            };
        }
    }

    return .too_large;
}

/// Bytes the CONNECT head reader buffers per read.
const connect_read_bytes = 8 * 1024;

/// What reading a CONNECT head found.
const ConnectHead = union(enum) {
    complete: usize,
    ended,
    too_large,
};

pub fn reply(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

/// Resolves the origin and connects to its addresses one at a time, the
/// resolution and each connect waiting at most until `deadline_ms` on the
/// awake clock and ending when the task is canceled. The name resolves on a
/// worker of `resolutions`, since the system resolver cannot be interrupted;
/// a dotted IPv4 address needs none. Connects run sequentially, which
/// avoids a Zig 0.16 Darwin race where concurrent connect attempts can
/// report EISCONN.
///
/// ```zig
/// const origin = try tunnel_namespace.connectUpstream(.{ .host = host, .io = io, .port = 443, .deadline_ms = deadline, .resolutions = resolutions, .telemetry = telemetry });
/// ```
pub fn connectUpstream(target: Upstream) !std.Io.net.Stream {
    const io = target.io;
    if (std.Io.net.IpAddress.parseIp4(target.host.bytes, target.port)) |address| {
        return connectBefore(io, address, target.deadline_ms);
    } else |_| {}

    var addresses: [Resolutions.max_addresses]std.Io.net.IpAddress = undefined;
    const found = try name_resolution.resolve(
        target.resolutions,
        .{
            .host = target.host,
            .io = io,
            .deadline_ms = target.deadline_ms,
        },
        &addresses,
    );
    if (found > addresses.len) {
        target.telemetry.record(.resolution_truncated);
    }

    var last_error: ?anyerror = null;
    for (addresses[0..@min(found, addresses.len)]) |*address| {
        address.setPort(target.port);
        if (connectBefore(io, address.*, target.deadline_ms)) |stream| {
            return stream;
        } else |err| {
            last_error = err;
            if (err == error.Timeout or err == error.Canceled) {
                return err;
            }
        }
    }

    return last_error orelse error.UnknownHostName;
}

/// Where a tunnel connects and by when.
const Upstream = struct {
    host: std.Io.net.HostName,
    resolutions: *Resolutions,
    telemetry: *Counters,
    io: std.Io,
    port: u16,
    /// On the awake clock.
    deadline_ms: i64,
};

/// Connects one address without blocking past `deadline_ms`, and gives up
/// as soon as its task is canceled.
fn connectBefore(io: std.Io, address: std.Io.net.IpAddress, deadline_ms: i64) !std.Io.net.Stream {
    if (deadline_ms <= now(io)) {
        return error.Timeout;
    }

    const family: c_uint = switch (address) {
        .ip4 => std.c.AF.INET,
        .ip6 => std.c.AF.INET6,
    };
    const handle = std.c.socket(family, std.c.SOCK.STREAM, 0);
    if (handle < 0) {
        return error.SystemResources;
    }
    errdefer _ = std.c.close(handle);

    try setCloseOnExec(handle);
    try setKeepalive(handle);
    try setNonblocking(handle, true);

    var storage: std.c.sockaddr.storage = undefined;
    const length = socketAddress(address, &storage);
    if (std.c.connect(handle, @ptrCast(&storage), length) != 0) {
        switch (std.posix.errno(-1)) {
            .INPROGRESS => try awaitConnect(io, handle, deadline_ms),
            else => return error.ConnectionRefused,
        }
    }

    try setNonblocking(handle, false);
    return .{
        .socket = .{
            .handle = handle,
            .address = address,
        },
    };
}

/// Waits for a nonblocking connect to finish by `deadline_ms`. It polls in
/// short slices and checks for cancellation between them, since a raw poll
/// is outside the runtime's cancelable calls, so stopping the proxy never
/// waits for an origin that does not answer. An interrupted poll retries.
fn awaitConnect(io: std.Io, handle: std.c.fd_t, deadline_ms: i64) !void {
    var pending = [_]std.c.pollfd{.{
        .fd = handle,
        .events = std.c.POLL.OUT,
        .revents = 0,
    }};

    while (true) {
        try io.checkCancel();

        const left_ms = deadline_ms - now(io);
        if (left_ms <= 0) {
            return error.Timeout;
        }

        const slice_ms: c_int = @intCast(@min(left_ms, connect_poll_slice_ms));
        const ready = std.c.poll(&pending, pending.len, slice_ms);
        if (ready > 0) {
            break;
        }

        if (ready < 0 and std.posix.errno(ready) != .INTR) {
            return error.SystemResources;
        }
    }

    var failure: c_int = 0;
    var failure_len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(handle, std.c.SOL.SOCKET, std.c.SO.ERROR, &failure, &failure_len) != 0 or failure != 0) {
        return error.ConnectionRefused;
    }
}

/// How long one poll of a pending connect lasts before it checks for
/// cancellation.
const connect_poll_slice_ms = 50;

fn setNonblocking(handle: std.c.fd_t, enabled: bool) !void {
    const flags = std.c.fcntl(handle, std.c.F.GETFL);
    if (flags < 0) {
        return error.SystemResources;
    }

    var status: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    status.NONBLOCK = enabled;
    if (std.c.fcntl(handle, std.c.F.SETFL, @as(c_int, @bitCast(status))) != 0) {
        return error.SystemResources;
    }
}

fn setCloseOnExec(handle: std.c.fd_t) !void {
    if (std.c.fcntl(handle, std.c.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) != 0) {
        return error.SystemResources;
    }
}

/// Turns TCP keepalive on for an origin socket. A relay that only reads
/// never learns that its origin vanished without closing, after a sleep or
/// a network change, and would hold its row for as long as the child waits.
/// With keepalive the kernel probes a connection silent for
/// `keepalive_idle_s` and ends it after `keepalive_probes` unanswered
/// probes, which fails the blocked read. An origin that answers its probes
/// is never closed, however long a model takes to answer.
fn setKeepalive(handle: std.c.fd_t) !void {
    const options = [_]SocketOption{
        .{
            .level = std.c.SOL.SOCKET,
            .name = std.c.SO.KEEPALIVE,
            .value = keepalive_enabled,
        },
        .{
            .level = std.c.IPPROTO.TCP,
            .name = keepalive_idle_option,
            .value = keepalive_idle_s,
        },
        .{
            .level = std.c.IPPROTO.TCP,
            .name = std.c.TCP.KEEPINTVL,
            .value = keepalive_interval_s,
        },
        .{
            .level = std.c.IPPROTO.TCP,
            .name = std.c.TCP.KEEPCNT,
            .value = keepalive_probes,
        },
    };

    for (options) |option| {
        if (std.c.setsockopt(handle, option.level, option.name, &option.value, @sizeOf(c_int)) != 0) {
            return error.SystemResources;
        }
    }
}

const SocketOption = struct {
    level: i32,
    name: u32,
    value: c_int,
};

const keepalive_enabled = 1;
/// Seconds an origin connection stays silent before its first probe.
const keepalive_idle_s = 60;
/// Seconds between probes.
const keepalive_interval_s = 10;
/// Unanswered probes that end the connection: a vanished origin is noticed
/// two minutes after its last byte.
const keepalive_probes = 6;
/// The idle time option, which Darwin names after the feature.
const keepalive_idle_option = if (builtin.os.tag.isDarwin()) std.c.TCP.KEEPALIVE else std.c.TCP.KEEPIDLE;

fn socketAddress(address: std.Io.net.IpAddress, storage: *std.c.sockaddr.storage) std.c.socklen_t {
    switch (address) {
        .ip4 => |ip4| {
            const destination: *std.c.sockaddr.in = @ptrCast(@alignCast(storage));
            destination.* = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            return @sizeOf(std.c.sockaddr.in);
        },
        .ip6 => |ip6| {
            const destination: *std.c.sockaddr.in6 = @ptrCast(@alignCast(storage));
            destination.* = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return @sizeOf(std.c.sockaddr.in6);
        },
    }
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Answers a connection the proxy refuses and lets the answer reach it: the
/// write side is shut down, then what the client already sent is drained
/// for at most `drain_ms`, so closing does not reset the connection and
/// discard the answer before the client reads it. The caller closes.
///
/// ```zig
/// tunnel_namespace.refuse(io, stream, "HTTP/1.1 503 Service Unavailable\r\n\r\n", 20);
/// ```
pub fn refuse(io: std.Io, stream: std.Io.net.Stream, answer: []const u8, drain_ms: i64) void {
    reply(io, stream, answer);
    stream.shutdown(io, .send) catch return;

    const deadline_ms = now(io) + drain_ms;
    var drained: usize = 0;
    var discard: [4096]u8 = undefined;
    while (drained < max_drained_bytes) {
        const left_ms = deadline_ms - now(io);
        if (left_ms <= 0) {
            return;
        }

        var pending = [_]std.c.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.c.POLL.IN,
            .revents = 0,
        }};
        if (std.c.poll(&pending, pending.len, @intCast(left_ms)) != pending.len) {
            return;
        }

        const count = std.c.recv(stream.socket.handle, &discard, discard.len, std.c.MSG.DONTWAIT);
        if (count <= 0) {
            return;
        }

        drained += @intCast(count);
    }
}

/// The most a refusal drains before it closes anyway.
const max_drained_bytes = 64 * 1024;

test "a refused client reads the whole answer after sending its request" {
    const io = std.testing.io;
    var sockets: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[1]);
    const proxy_side: std.Io.net.Stream = .{
        .socket = .{
            .handle = sockets[0],
            .address = .{
                .ip4 = .loopback(0),
            },
        },
    };
    const request = "CONNECT example.test:443 HTTP/1.1\r\n\r\n";
    try std.testing.expectEqual(@as(isize, request.len), std.c.send(sockets[1], request, request.len, 0));

    refuse(io, proxy_side, "HTTP/1.1 503 Service Unavailable\r\n\r\n", 50);
    proxy_side.close(io);

    var answer: [64]u8 = undefined;
    const count = std.c.recv(sockets[1], &answer, answer.len, 0);
    try std.testing.expectEqualStrings("HTTP/1.1 503 Service Unavailable\r\n\r\n", answer[0..@intCast(count)]);
}

test "a connect that cannot finish before its deadline times out" {
    const io = std.testing.io;

    try std.testing.expectError(error.Timeout, connectBefore(io, unroutable, now(io)));
    const started = now(io);
    const result = connectBefore(io, unroutable, started + 100);
    if (result) |stream| {
        stream.close(io);
        return error.UnexpectedConnect;
    } else |err| {
        try std.testing.expect(err == error.Timeout or err == error.ConnectionRefused);
    }

    try std.testing.expect(now(io) - started < 2 * std.time.ms_per_s);
}

test "a pending connect gives up as soon as its task is canceled" {
    const io = std.testing.io;
    var pending = try io.concurrent(connectBefore, .{
        io,
        unroutable,
        now(io) + 30 * std.time.ms_per_s,
    });
    try io.sleep(.fromMilliseconds(100), .awake);

    const started = now(io);
    const result = pending.cancel(io);
    if (result) |stream| {
        stream.close(io);
        return error.UnexpectedConnect;
    } else |err| {
        try std.testing.expect(err == error.Canceled or err == error.ConnectionRefused);
    }

    try std.testing.expect(now(io) - started < std.time.ms_per_s);
}

test "an origin socket probes a silent origin and gives it up after its unanswered probes" {
    const io = std.testing.io;
    const loopback: std.Io.net.IpAddress = .{
        .ip4 = .loopback(0),
    };
    var origin = try loopback.listen(io, .{});
    defer origin.deinit(io);

    const stream = try connectBefore(io, origin.socket.address, now(io) + std.time.ms_per_s);
    defer stream.close(io);

    try std.testing.expect(try socketOption(stream.socket.handle, std.c.SOL.SOCKET, std.c.SO.KEEPALIVE) != 0);
    try std.testing.expectEqual(@as(c_int, keepalive_idle_s), try socketOption(stream.socket.handle, std.c.IPPROTO.TCP, keepalive_idle_option));
    try std.testing.expectEqual(@as(c_int, keepalive_interval_s), try socketOption(stream.socket.handle, std.c.IPPROTO.TCP, std.c.TCP.KEEPINTVL));
    try std.testing.expectEqual(@as(c_int, keepalive_probes), try socketOption(stream.socket.handle, std.c.IPPROTO.TCP, std.c.TCP.KEEPCNT));
}

fn socketOption(handle: std.c.fd_t, level: i32, name: u32) !c_int {
    var value: c_int = 0;
    var value_len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(handle, level, name, &value, &value_len) != 0) {
        return error.SocketOptionUnreadable;
    }

    return value;
}

/// 192.0.2.0/24 is reserved for documentation and never answers.
const unroutable: std.Io.net.IpAddress = .{
    .ip4 = .{
        .bytes = .{ 192, 0, 2, 1 },
        .port = 443,
    },
};

test "authentication rejection records total and exact reason" {
    var invalid: Counters = .{};
    recordAuthenticationRejection(&invalid, .invalid_authorization);
    const invalid_snapshot = snapshot(&invalid);

    try std.testing.expectEqual(@as(u64, 1), invalid_snapshot.rejected_connections);
    try std.testing.expectEqual(@as(u64, 1), invalid_snapshot.invalid_authorization_rejections);
    try std.testing.expectEqual(@as(u64, 0), invalid_snapshot.unknown_credential_rejections);

    var unknown: Counters = .{};
    recordAuthenticationRejection(&unknown, .unknown_credential);
    const unknown_snapshot = snapshot(&unknown);

    try std.testing.expectEqual(@as(u64, 1), unknown_snapshot.rejected_connections);
    try std.testing.expectEqual(@as(u64, 0), unknown_snapshot.invalid_authorization_rejections);
    try std.testing.expectEqual(@as(u64, 1), unknown_snapshot.unknown_credential_rejections);
}

fn snapshot(telemetry: *const Counters) Snapshot {
    return telemetry.snapshot(.{
        .connections = .{
            .active = 0,
            .limit_drops = 0,
        },
    });
}
