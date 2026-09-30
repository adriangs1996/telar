//! Runtime-owned loopback ProxyTLS service.

const core = @import("telar-core");
const std = @import("std");
const Connections = @import("../Connections.zig");
const Tunnel = @import("../tunnel/Tunnel.zig");

pub const max_connections: u32 = Connections.capacity;
pub const connections_limit = core.Limit.declare("proxy.max_connections", "connections", max_connections);

pub const Paths = @import("Paths.zig");

pub const ClientConfiguration = @import("ClientConfiguration.zig");

pub const Worker = std.Io.Future(anyerror!void);

pub const Service = @import("Service.zig");

/// How often the service closes connections past their deadlines.
const reap_interval_ms = std.time.ms_per_s;
/// How long a full table waits for an evicted connection to free its row.
const eviction_wait_ms = 100;
/// How often that wait looks for the free row.
const eviction_poll_ms = 5;
/// How long accepting pauses after the process ran out of descriptors, so
/// the loop waits for a tunnel to close one instead of spinning.
const descriptor_backoff_ms = 100;
/// Descriptors the runtime keeps for everything but proxy connections:
/// panes, clients, history and logs.
const reserved_descriptors = 1024;
/// Descriptors a proxy connection holds: its child and its origin.
const descriptors_per_connection = 2;
/// The answer to a connection that finds every slot taken.
const refusal = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// Accepts until cancellation or listener closure. A started connection owns
/// its stream and its row; a connection over the bound is answered 503 and
/// closed here, after the idle connection that was idle the longest, if any,
/// was closed to make room for it. Transient accept failures are retried.
///
/// ```zig
/// try service_support.acceptConnections(service);
/// ```
pub fn acceptConnections(service: *Service) anyerror!void {
    var connections: std.Io.Group = .init;
    defer connections.cancel(service.io);

    while (true) {
        const stream = service.listener.accept(service.io) catch |err| switch (err) {
            error.Canceled => |canceled| return canceled,
            error.SocketNotListening => return,
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                try pause(service.io, descriptor_backoff_ms);
                continue;
            },
            else => continue,
        };

        const slot = try admit(service, stream.socket.handle) orelse {
            service.connections.refuse();
            refuse(service.io, stream);
            continue;
        };

        connections.concurrent(service.io, serveConnection, .{ service, stream, slot }) catch {
            close(service, stream, slot);
        };
    }
}

/// Raises the process's soft descriptor limit, within its hard limit, so
/// every proxy connection fits beside the rest of the runtime. A launcher
/// such as launchd starts processes with 256. A limit that cannot be raised
/// is kept; accepting then backs off when descriptors run out.
///
/// ```zig
/// service_support.raiseDescriptorLimit();
/// ```
pub fn raiseDescriptorLimit() void {
    const wanted: std.posix.rlim_t = max_connections * descriptors_per_connection + reserved_descriptors;
    var limits = std.posix.getrlimit(.NOFILE) catch return;
    if (limits.cur >= wanted) {
        return;
    }

    limits.cur = @min(wanted, limits.max);
    std.posix.setrlimit(.NOFILE, limits) catch {};
}

/// Closes every connection past its CONNECT head or establishment deadline,
/// once a second, until the service stops.
///
/// ```zig
/// try service_support.expireConnections(service);
/// ```
pub fn expireConnections(service: *Service) anyerror!void {
    while (true) {
        try pause(service.io, reap_interval_ms);

        const expired = service.connections.expire(now(service.io));
        for (0..expired.connect_head) |_| {
            service.telemetry.record(.connect_head_timeout);
        }

        for (0..expired.establishing) |_| {
            service.telemetry.record(.establish_timeout);
        }
    }
}

/// A row for a new connection: a free one, or the one an evicted idle
/// connection frees within `eviction_wait_ms`.
fn admit(service: *Service, child: Connections.Handle) std.Io.Cancelable!?Connections.Slot {
    if (service.connections.acquire(child, now(service.io))) |slot| {
        return slot;
    }

    if (!service.connections.evictIdle(now(service.io))) {
        return null;
    }

    service.telemetry.record(.idle_eviction);
    var waited_ms: u32 = 0;
    while (waited_ms < eviction_wait_ms) : (waited_ms += eviction_poll_ms) {
        try pause(service.io, eviction_poll_ms);
        if (service.connections.acquire(child, now(service.io))) |slot| {
            return slot;
        }
    }

    return null;
}

fn serveConnection(service: *Service, stream: std.Io.net.Stream, slot: Connections.Slot) std.Io.Cancelable!void {
    defer close(service, stream, slot);

    var tunnel = Tunnel.init(.{
        .dependencies = .{
            .tls = service.interception.tunnelResources(&service.telemetry),
            .secret = &service.secret,
            .connection_ids = &service.next_connection_id,
            .captures = &service.captures,
            .connections = &service.connections,
        },
        .child = stream,
        .slot = slot,
    });

    return tunnel.run();
}

/// Closes a connection's child socket only after its row stops every
/// shutdown, so none reaches a descriptor reused by the next accept.
fn close(service: *Service, stream: std.Io.net.Stream, slot: Connections.Slot) void {
    service.connections.retire(slot);
    stream.close(service.io);
    service.connections.release(slot);
}

fn refuse(io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);

    var buffer: [refusal.len]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(refusal) catch return;
    writer.interface.flush() catch return;
    stream.shutdown(io, .send) catch {};
}

fn pause(io: std.Io, duration_ms: i64) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(duration_ms), .awake);
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

test "the descriptor limit rises to fit every connection within its hard limit" {
    const original = try std.posix.getrlimit(.NOFILE);
    defer std.posix.setrlimit(.NOFILE, original) catch {};

    const wanted: std.posix.rlim_t = max_connections * descriptors_per_connection + reserved_descriptors;
    var lowered = original;
    lowered.cur = @min(original.cur, 256);
    try std.posix.setrlimit(.NOFILE, lowered);

    raiseDescriptorLimit();
    const raised = try std.posix.getrlimit(.NOFILE);
    try std.testing.expectEqual(@min(wanted, original.max), raised.cur);
}
