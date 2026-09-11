//! Runtime-owned loopback ProxyTLS service.

const std = @import("std");
const core = @import("telar-core");
pub const diagnostics = core.diagnostics;
const configuration_mod = @import("configuration_support.zig");
const capture_mod = @import("../capture/root.zig");
const connection_admission = @import("../connection_admission.zig");
const credential_registry = @import("../credential_registry.zig");
const identity = @import("../identity.zig");
const interception_mod = @import("interception_support.zig");
const listener_mod = @import("listener_support.zig");
const metrics_mod = @import("../metrics.zig");
const middleware = @import("../middleware.zig");
const observations_mod = @import("observations_support.zig");
const tunnel_mod = @import("../tunnel/root.zig");

pub const Io = std.Io;
const net = Io.net;
pub const schema = core.schema;

pub const max_connections: u32 = 64;

pub const Paths = interception_mod.Paths;

pub const Pane = @import("Pane.zig");

pub const ClientConfiguration = @import("ClientConfiguration.zig");

pub const Worker = Io.Future(anyerror!void);

pub const Service = @import("Service.zig");

const connection_admission_port: connection_admission.Port(Service, net.Stream) = .{
    .accept = acceptConnection,
    .acquire = acquireConnection,
    .start = startConnection,
    .release = releaseConnection,
    .close = closeConnection,
    .cancel = cancelConnections,
};

pub const ConnectionAdmission = connection_admission.Runner(Service, net.Stream, connection_admission_port);

fn acceptConnection(service: *Service) !net.Stream {
    return service.listener.accept(service.io);
}

fn acquireConnection(service: *Service) bool {
    return service.connection_slots.acquire();
}

fn startConnection(service: *Service, connections: *Io.Group, stream: net.Stream) !void {
    try connections.concurrent(service.io, serveConnection, .{ service, stream });
}

fn serveConnection(service: *Service, stream: net.Stream) Io.Cancelable!void {
    defer service.connection_slots.release();
    const configuration = service.configuration.view();

    var tunnel = tunnel_mod.Tunnel.init(.{
        .dependencies = .{
            .tls = service.interception.tunnelResources(&service.telemetry),
            .credentials = &service.credentials,
            .pipeline = service.observations.pipeline(),
            .transforms = configuration.transforms,
            .has_custom_transformers = configuration.has_custom_transformers,
            .connection_ids = &service.next_connection_id,
            .captures = &service.captures,
        },
        .child = stream,
    });

    return tunnel.run();
}

fn releaseConnection(service: *Service) void {
    service.connection_slots.release();
}

fn closeConnection(service: *Service, stream: net.Stream) void {
    stream.close(service.io);
}

fn cancelConnections(service: *Service, connections: *Io.Group) void {
    connections.cancel(service.io);
}

pub fn observationCredentialIsLive(context: *anyopaque, credential: *const identity.Credential) bool {
    const service: *Service = @ptrCast(@alignCast(context));
    return service.credentials.contains(service.io, credential);
}
