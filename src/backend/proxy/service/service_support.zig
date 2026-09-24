//! Runtime-owned loopback ProxyTLS service.

const std = @import("std");
const Tunnel = @import("../tunnel/Tunnel.zig");

pub const max_connections: u32 = 64;

pub const Paths = @import("Paths.zig");

pub const Pane = @import("Pane.zig");

pub const ClientConfiguration = @import("ClientConfiguration.zig");

pub const Worker = std.Io.Future(anyerror!void);

pub const Service = @import("Service.zig");

/// Accepts until cancellation or listener closure. A started connection owns
/// its stream and its slot; a connection over the bound, or one that cannot
/// be scheduled, is closed here after its slot is released. Transient accept
/// failures are retried.
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
            else => continue,
        };

        if (!service.connection_slots.acquire()) {
            stream.close(service.io);
            continue;
        }

        connections.concurrent(service.io, serveConnection, .{ service, stream }) catch {
            service.connection_slots.release();
            stream.close(service.io);
        };
    }
}

fn serveConnection(service: *Service, stream: std.Io.net.Stream) std.Io.Cancelable!void {
    defer service.connection_slots.release();

    var tunnel = Tunnel.init(.{
        .dependencies = .{
            .tls = service.interception.tunnelResources(&service.telemetry),
            .credentials = &service.credentials,
            .observations = &service.observations,
            .connection_ids = &service.next_connection_id,
            .captures = &service.captures,
        },
        .child = stream,
    });

    return tunnel.run();
}
