//! Runtime-owned loopback ProxyTLS service.

const std = @import("std");
const GenericConnectionAdmissionPort = @import("../GenericConnectionAdmissionPort.zig").Type;
const GenericRunner = @import("../GenericRunner.zig").Type;
const TunnelType = @import("../tunnel/Tunnel.zig");
const CredentialType = @import("../Credential.zig");

pub const max_connections: u32 = 64;

pub const Paths = @import("Paths.zig");

pub const Pane = @import("Pane.zig");

pub const ClientConfiguration = @import("ClientConfiguration.zig");

pub const Worker = std.Io.Future(anyerror!void);

pub const Service = @import("Service.zig");

const connection_admission_port: GenericConnectionAdmissionPort(Service, std.Io.net.Stream) = .{
    .accept = acceptConnection,
    .acquire = acquireConnection,
    .start = startConnection,
    .release = releaseConnection,
    .close = closeConnection,
    .cancel = cancelConnections,
};

pub const ConnectionAdmission = GenericRunner(Service, std.Io.net.Stream, connection_admission_port);

fn acceptConnection(service: *Service) !std.Io.net.Stream {
    return service.listener.accept(service.io);
}

fn acquireConnection(service: *Service) bool {
    return service.connection_slots.acquire();
}

fn startConnection(service: *Service, connections: *std.Io.Group, stream: std.Io.net.Stream) !void {
    try connections.concurrent(service.io, serveConnection, .{ service, stream });
}

fn serveConnection(service: *Service, stream: std.Io.net.Stream) std.Io.Cancelable!void {
    defer service.connection_slots.release();
    const configuration = service.configuration.view();

    var tunnel = TunnelType.init(.{
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

fn closeConnection(service: *Service, stream: std.Io.net.Stream) void {
    stream.close(service.io);
}

fn cancelConnections(service: *Service, connections: *std.Io.Group) void {
    connections.cancel(service.io);
}

pub fn observationCredentialIsLive(context: *anyopaque, credential: *const CredentialType) bool {
    const service: *Service = @ptrCast(@alignCast(context));
    return service.credentials.contains(service.io, credential);
}
