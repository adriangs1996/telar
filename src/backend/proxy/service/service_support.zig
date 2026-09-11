//! Runtime-owned loopback ProxyTLS service.

const ServiceType = @import("Service.zig");
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

const connection_admission_port: GenericConnectionAdmissionPort(ServiceType, std.Io.net.Stream) = .{
    .accept = acceptConnection,
    .acquire = acquireConnection,
    .start = startConnection,
    .release = releaseConnection,
    .close = closeConnection,
    .cancel = cancelConnections,
};

pub const ConnectionAdmission = GenericRunner(ServiceType, std.Io.net.Stream, connection_admission_port);

fn acceptConnection(service: *ServiceType) !std.Io.net.Stream {
    return service.listener.accept(service.io);
}

fn acquireConnection(service: *ServiceType) bool {
    return service.connection_slots.acquire();
}

fn startConnection(service: *ServiceType, connections: *std.Io.Group, stream: std.Io.net.Stream) !void {
    try connections.concurrent(service.io, serveConnection, .{ service, stream });
}

fn serveConnection(service: *ServiceType, stream: std.Io.net.Stream) std.Io.Cancelable!void {
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

fn releaseConnection(service: *ServiceType) void {
    service.connection_slots.release();
}

fn closeConnection(service: *ServiceType, stream: std.Io.net.Stream) void {
    stream.close(service.io);
}

fn cancelConnections(service: *ServiceType, connections: *std.Io.Group) void {
    connections.cancel(service.io);
}

pub fn observationCredentialIsLive(context: *anyopaque, credential: *const CredentialType) bool {
    const service: *ServiceType = @ptrCast(@alignCast(context));
    return service.credentials.contains(service.io, credential);
}
