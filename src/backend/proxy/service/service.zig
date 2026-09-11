const Service = @This();
const source_namespace = @import("service_support.zig");
const std = @import("std");
const listener_mod = @import("listener_support.zig");
const interception_mod = @import("interception_support.zig");
const credential_registry = @import("../credential_registry.zig");
const configuration_mod = @import("configuration_support.zig");
const observations_mod = @import("observations_support.zig");
const capture_mod = @import("../capture/root.zig");
const connection_admission = @import("../connection_admission.zig");
const metrics_mod = @import("../metrics.zig");
const ClientConfiguration = @import("ClientConfiguration.zig");
const middleware = @import("../middleware.zig");
const identity = @import("../identity.zig");
const Pane = @import("Pane.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
listener: listener_mod.Listener,
interception: interception_mod.Interception,
credentials: credential_registry.Registry = .{},
configuration: configuration_mod.Configuration,
observations: observations_mod.Observations = undefined,
captures: capture_mod.Producer = undefined,
connection_slots: connection_admission.Slots = .init(source_namespace.max_connections),
telemetry: metrics_mod.Counters = .{},
next_connection_id: std.atomic.Value(u64) = .init(1),

/// Builds the loopback listener and every bounded dependency without
/// starting concurrent traffic. Ownership transfers to the returned
/// service on success.
///
/// ```zig
/// const service = try Service.create(io, gpa, paths);
/// defer service.destroy();
/// ```
pub fn create(io: source_namespace.Io, gpa: std.mem.Allocator, paths: source_namespace.Paths) !*Service {
    var interception = try interception_mod.Interception.init(io, gpa, paths);
    errdefer interception.deinit();

    var listener = try listener_mod.Listener.bind(io);
    errdefer listener.deinit(io);

    const configuration = try configuration_mod.Configuration.init();

    const service = try gpa.create(Service);
    errdefer gpa.destroy(service);
    service.* = .{
        .io = io,
        .gpa = gpa,
        .listener = listener,
        .interception = interception,
        .configuration = configuration,
        .observations = undefined,
    };
    try service.observations.init(.{
        .context = service,
        .is_live = source_namespace.observationCredentialIsLive,
    });
    try service.captures.init(gpa, .{
        .config = paths.capture,
        .gate = .{
            .context = service,
            .is_live = source_namespace.observationCredentialIsLive,
        },
    });

    return service;
}

/// Releases the stopped service and scrubs its in-memory authority and
/// credentials. Call `cancel` and `close` before destroying a started
/// service.
///
/// ```zig
/// service.destroy();
/// ```
pub fn destroy(service: *Service) void {
    const gpa = service.gpa;
    service.listener.deinit(service.io);
    service.interception.deinit();
    std.crypto.secureZero(u8, std.mem.asBytes(service));
    gpa.destroy(service);
}

/// Starts the listener worker. The returned worker owns the running accept
/// loop until it is passed to `cancel`.
///
/// ```zig
/// var worker = try service.start();
/// defer service.cancel(&worker);
/// ```
pub fn start(service: *Service) !source_namespace.Worker {
    return service.io.concurrent(run, .{service});
}

/// Cancels and joins the listener worker before service resources are
/// released.
///
/// ```zig
/// service.cancel(&worker);
/// ```
pub fn cancel(service: *Service, worker: *source_namespace.Worker) void {
    _ = worker.cancel(service.io) catch {};
}

/// Closes observation delivery after the listener worker has stopped.
///
/// ```zig
/// service.close();
/// ```
pub fn close(service: *Service) void {
    service.observations.close(service.io);
    service.captures.close(service.io);
}

/// Returns the stable connection and trust configuration inherited by
/// children registered with this service.
///
/// ```zig
/// const client = service.clientConfiguration();
/// ```
pub fn clientConfiguration(service: *const Service) ClientConfiguration {
    const trust = service.interception.clientTrust();

    return .{
        .port = service.listener.port(),
        .certificate_path = trust.certificate_path,
        .bundle_path = trust.bundle_path,
    };
}

fn run(service: *Service) anyerror!void {
    const path = source_namespace.diagnostics.enter(.observation);
    defer path.restore();
    try service.configuration.beginServing(service.io);

    return source_namespace.ConnectionAdmission.run(service);
}

/// Waits for the next live observation. Events for credentials revoked
/// while queued are discarded before this method returns.
///
/// ```zig
/// var event = try service.receive(io);
/// defer std.crypto.secureZero(u8, &event.credential.token);
/// ```
pub fn receive(service: *Service, io: source_namespace.Io) anyerror!middleware.Event {
    return service.observations.receive(io);
}

/// Waits for one captured half whose pane credential remains live.
///
/// ```zig
/// const half = try service.receiveCapture(io);
/// ```
pub fn receiveCapture(service: *Service, io: source_namespace.Io) anyerror!*capture_mod.Half {
    return service.captures.receive(io);
}

/// Decodes a captured body outside the traffic relay task.
///
/// ```zig
/// service.decodeCapture(half);
/// ```
pub fn decodeCapture(service: *Service, half: *capture_mod.Half) void {
    service.captures.decodeBody(half);
}

/// Returns one lock-free snapshot without exposing queue, admission, or
/// counter storage to the caller.
///
/// ```zig
/// const snapshot = service.metrics();
/// ```
pub fn metrics(service: *const Service) metrics_mod.Snapshot {
    return service.telemetry.snapshot(.{
        .connections = service.connection_slots.snapshot(),
        .observations = service.observations.metrics(),
        .captures = service.captures.metrics(),
    });
}

/// Formats the loopback proxy URL for a credential into caller-owned
/// storage.
///
/// ```zig
/// const url = try service.credentialUrl(&buffer, &credential);
/// ```
pub fn credentialUrl(service: *const Service, buffer: []u8, credential: *const identity.Credential) ![]const u8 {
    return identity.formatUrl(buffer, service.listener.port(), credential);
}

/// Creates and registers a fresh capability for one pane generation. The
/// caller owns the returned secret and must scrub it after use.
///
/// ```zig
/// var credential = try service.registerPane(.{ .id = pane_id, .generation = 2 });
/// defer std.crypto.secureZero(u8, &credential.token);
/// ```
pub fn registerPane(service: *Service, pane: Pane) !identity.Credential {
    var credential: identity.Credential = .{
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .token = identity.randomToken(service.io),
    };
    errdefer std.crypto.secureZero(u8, &credential.token);

    try service.registerCredential(&credential);

    return credential;
}

fn registerCredential(service: *Service, credential: *const identity.Credential) !void {
    return service.credentials.register(service.io, credential);
}

/// Revokes one exact credential, including rollback of an incomplete pane
/// registration.
///
/// ```zig
/// service.unregisterCredential(&credential);
/// ```
pub fn unregisterCredential(service: *Service, credential: *const identity.Credential) void {
    service.credentials.remove(service.io, credential);
}

/// Revokes every credential issued for one exact pane generation.
///
/// ```zig
/// service.unregisterPane(.{ .id = pane_id, .generation = 2 });
/// ```
pub fn unregisterPane(service: *Service, pane: Pane) void {
    service.credentials.removePane(service.io, .{ .id = pane.id, .generation = pane.generation });
}

/// Register before `run` starts. The immutable pipeline can later be
/// backed by a bounded worker without giving it access to tunnel state.
///
/// ```zig
/// try service.addTransformer(transformer);
/// ```
pub fn addTransformer(service: *Service, transformer: middleware.Transformer) !void {
    return service.configuration.add(service.io, transformer);
}
