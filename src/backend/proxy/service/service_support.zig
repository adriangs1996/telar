//! Runtime-owned loopback ProxyTLS service.

const core = @import("telar-core");
const pty = @import("pty");
const std = @import("std");
const Connections = @import("../Connections.zig");
const name_resolution = @import("../name_resolution.zig");
const Resolutions = @import("../Resolutions.zig");
const Tunnel = @import("../tunnel/Tunnel.zig");
const tunnel_namespace = @import("../tunnel/tunnel_namespace.zig");

pub const max_connections: u32 = Connections.capacity;
pub const connections_limit = core.Limit.declare("proxy.max_connections", "connections", max_connections);

pub const Paths = @import("Paths.zig");

pub const ClientConfiguration = @import("ClientConfiguration.zig");

pub const Worker = std.Io.Future(anyerror!void);

pub const Service = @import("Service.zig");

/// How often the service closes connections past their deadlines.
const reap_interval_ms = std.time.ms_per_s;
/// How long a stopping service waits for its tunnels once their sockets are
/// shut down and their tasks canceled. A tunnel returns well before that
/// unless it is inside a call neither interrupts, such as the system
/// resolver; the service then stops without it.
pub const stop_timeout_ms: i64 = 2 * std.time.ms_per_s;
pub const stop_timeout_limit = core.Limit.declare("proxy.stop_timeout_ms", "ms", stop_timeout_ms);
/// How long a full table waits for an evicted connection to free its row.
const eviction_wait_ms = 100;
/// How often that wait looks for the free row.
const eviction_poll_ms = 5;
/// How long accepting pauses after the process ran out of descriptors, so
/// the loop waits for a tunnel to close one instead of spinning.
const descriptor_backoff_ms = 100;
/// Descriptors the runtime keeps for everything but the proxy: panes,
/// clients, history and logs.
const reserved_descriptors = 448;
/// Descriptors a proxy connection holds: its child and its origin.
const descriptors_per_connection = 2;
/// Descriptors a name resolution holds once every tunnel gave up on it:
/// measured on macOS 26, `getaddrinfo` keeps one open per call in flight.
/// While a tunnel still waits, the resolution takes the place of the origin
/// socket that tunnel has yet to open.
const descriptors_per_resolution = 1;
/// What the proxy at its bounds and the rest of the runtime may hold.
const wanted_descriptors = max_connections * descriptors_per_connection + Resolutions.capacity * descriptors_per_resolution + reserved_descriptors;
/// How long the accept loop drains a refused connection so its 503 is not
/// lost to a reset; short, since accepting waits for it.
const refusal_drain_ms = 20;
comptime {
    std.debug.assert(wanted_descriptors <= pty.descriptor_limit.select_descriptor_ceiling);
}

/// The name resolutions of every proxy this process starts. It is static
/// because a resolution outlives its proxy: a worker blocked in the system
/// resolver returns whenever the resolver lets it, to a row that must still
/// be there. Stopping a proxy leaves such rows to their workers.
pub var resolutions: Resolutions = .{
    .resolver = name_resolution.askSystem,
};

/// The answer to a connection that finds every slot taken.
const refusal = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// Accepts until cancellation or listener closure. A started connection owns
/// its stream and its row, and its tunnel joins `service.tunnels`, which
/// outlives this loop: the reaper cancels them when the service stops. A
/// connection over the bound is answered 503 and closed here, after the idle
/// connection that was idle the longest, if any, was closed to make room for
/// it. Transient accept failures are retried.
///
/// ```zig
/// try service_support.acceptConnections(service);
/// ```
pub fn acceptConnections(service: *Service) anyerror!void {
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

        const admission = admit(service, stream.socket.handle) catch |err| {
            stream.close(service.io);
            return err;
        };

        const slot = switch (admission) {
            .admitted => |slot| slot,
            .full => {
                service.connections.refuse();
                refuse(service.io, stream);
                continue;
            },
            .unauthenticated_full => {
                service.telemetry.record(.unauthenticated_refusal);
                refuse(service.io, stream);
                continue;
            },
        };

        service.tunnels.concurrent(service.io, serveConnection, .{ service, stream, slot }) catch {
            close(service, stream, slot);
        };
    }
}

/// Raises the process's soft descriptor limit so every proxy connection
/// fits beside the rest of the runtime: 256 connections of two sockets, 64
/// blocked name resolutions of one descriptor and 448 more make 1024, which
/// is also the most a raise gives, so no child ever inherits a limit past
/// what select() holds (`pty.descriptor_limit`).
/// A launcher such as launchd starts processes with 256. A limit that
/// cannot be raised is kept; accepting then backs off when descriptors run
/// out.
///
/// ```zig
/// service_support.raiseDescriptorLimit();
/// ```
pub fn raiseDescriptorLimit() void {
    pty.descriptor_limit.raise(wanted_descriptors);
}

/// Closes every connection past its CONNECT head or establishment deadline,
/// and every one a side left that went silent, once a second, until the
/// service stops. Only the two deadlines count as limits reached; closing a
/// half-closed connection is routine. Then it cancels every tunnel and
/// waits for them, however long they take, and sets
/// `service.tunnels_joined`. That wait lives on this task so `Service.stop`
/// can bound its own with `awaitTunnels` and leave.
///
/// ```zig
/// service_support.reapConnections(service);
/// ```
pub fn reapConnections(service: *Service) void {
    while (!stopRequested(service)) {
        const expired = service.connections.expire(now(service.io));
        for (0..expired.connect_head) |_| {
            service.telemetry.record(.connect_head_timeout);
        }

        for (0..expired.establishing) |_| {
            service.telemetry.record(.establish_timeout);
        }
    }

    service.tunnels.cancel(service.io);
    service.tunnels_joined.set(service.io);
}

/// Waits one reap interval and returns whether the service stops. A
/// spurious wake only makes one round early.
fn stopRequested(service: *Service) bool {
    const interval: std.Io.Timeout = .{
        .duration = .{
            .raw = .fromMilliseconds(reap_interval_ms),
            .clock = .awake,
        },
    };
    service.stopping.waitTimeout(service.io, interval) catch |err| switch (err) {
        error.Timeout => return service.stopping.isSet(),
        error.Canceled => return true,
    };

    return true;
}

/// Waits until every tunnel returned, at most `stop_timeout_ms`, and
/// returns whether they did.
///
/// ```zig
/// if (!service_support.awaitTunnels(service)) return .abandoned;
/// ```
pub fn awaitTunnels(service: *Service) bool {
    const deadline_ms = now(service.io) + stop_timeout_ms;
    while (!service.tunnels_joined.isSet()) {
        const left_ms = deadline_ms - now(service.io);
        if (left_ms <= 0) {
            return false;
        }

        const left: std.Io.Timeout = .{
            .duration = .{
                .raw = .fromMilliseconds(left_ms),
                .clock = .awake,
            },
        };
        service.tunnels_joined.waitTimeout(service.io, left) catch {};
    }

    return true;
}

/// A row for a new connection. At `max_unauthenticated` connections still
/// sending their CONNECT head, one of them that had a second is closed, or
/// the new one is refused. Then a free row, or the one a connection closed
/// to make room frees within `eviction_wait_ms`.
fn admit(service: *Service, child: Connections.Handle) std.Io.Cancelable!Admission {
    const connections = &service.connections;
    if (connections.unauthenticated() >= Connections.max_unauthenticated) {
        if (!connections.evict(now(service.io), .unauthenticated)) {
            return .unauthenticated_full;
        }

        service.telemetry.record(.unauthenticated_eviction);
    }

    if (connections.acquire(child, now(service.io))) |slot| {
        return .{
            .admitted = slot,
        };
    }

    if (!connections.evict(now(service.io), .any)) {
        return .full;
    }

    service.telemetry.record(.eviction);
    var waited_ms: u32 = 0;
    while (waited_ms < eviction_wait_ms) : (waited_ms += eviction_poll_ms) {
        try pause(service.io, eviction_poll_ms);
        if (connections.acquire(child, now(service.io))) |slot| {
            return .{
                .admitted = slot,
            };
        }
    }

    return .full;
}

/// Whether a new connection got a row, or why not.
const Admission = union(enum) {
    admitted: Connections.Slot,
    /// Every row is taken and none could be freed in time.
    full,
    /// `max_unauthenticated` connections are still sending their CONNECT
    /// head, none of them for a second yet.
    unauthenticated_full,
};

fn serveConnection(service: *Service, stream: std.Io.net.Stream, slot: Connections.Slot) std.Io.Cancelable!void {
    const establishment: Establishment = .{
        .resolutions = &resolutions,
        .timeout_ms = Connections.establish_timeout_ms,
    };

    return serve(service, stream, slot, establishment);
}

/// Runs one admitted connection's tunnel until it ends, then closes its
/// socket and frees its row. `establishment` says where its host name
/// resolves and how long it may take to reach its origin.
///
/// ```zig
/// try service_support.serve(service, stream, slot, .{ .resolutions = &service_support.resolutions, .timeout_ms = Connections.establish_timeout_ms });
/// ```
pub fn serve(service: *Service, stream: std.Io.net.Stream, slot: Connections.Slot, establishment: Establishment) std.Io.Cancelable!void {
    defer close(service, stream, slot);

    if (service.tunnel_gate) |gate| {
        gate.hold(service.io);
    }

    var tunnel = Tunnel.init(.{
        .dependencies = .{
            .tls = service.interception.tunnelResources(&service.telemetry),
            .secret = &service.secret,
            .connection_ids = &service.next_connection_id,
            .captures = &service.captures,
            .connections = &service.connections,
            .resolutions = establishment.resolutions,
            .establish_timeout_ms = establishment.timeout_ms,
        },
        .child = stream,
        .slot = slot,
    });

    return tunnel.run();
}

/// Where a tunnel's host name resolves and how long it may take to reach
/// its origin.
const Establishment = struct {
    resolutions: *Resolutions,
    timeout_ms: i64,
};

/// Closes a connection's child socket only after its row stops every
/// shutdown, so none reaches a descriptor reused by the next accept.
fn close(service: *Service, stream: std.Io.net.Stream, slot: Connections.Slot) void {
    service.connections.retire(slot);
    stream.close(service.io);
    service.connections.release(slot);
}

fn refuse(io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);

    tunnel_namespace.refuse(io, stream, refusal, refusal_drain_ms);
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

    const wanted: std.posix.rlim_t = wanted_descriptors;
    var lowered = original;
    lowered.cur = @min(original.cur, 256);
    try std.posix.setrlimit(.NOFILE, lowered);

    raiseDescriptorLimit();
    const raised = try std.posix.getrlimit(.NOFILE);
    try std.testing.expectEqual(@min(wanted, pty.descriptor_limit.select_descriptor_ceiling, original.max), raised.cur);
}
