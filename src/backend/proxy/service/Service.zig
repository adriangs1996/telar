const core = @import("telar-core");
const std = @import("std");
const Listener = @import("Listener.zig");
const Interception = @import("Interception.zig");
const Registry = @import("../Registry.zig");
const Configuration = @import("Configuration.zig");
const Observations = @import("Observations.zig");
const Producer = @import("../capture/Producer.zig");
const Slots = @import("../Slots.zig");
const service_support = @import("service_support.zig");
const Counters = @import("../Counters.zig");
const Paths = @import("Paths.zig");
const ClientConfiguration = @import("ClientConfiguration.zig");
const MiddlewareEvent = @import("../MiddlewareEvent.zig");
const Half = @import("../capture/Half.zig");
const Snapshot = @import("../Snapshot.zig");
const Credential = @import("../Credential.zig");
const identity = @import("../identity.zig");
const Pane = @import("Pane.zig");
const Service = @This();

io: std.Io,
gpa: std.mem.Allocator,
listener: Listener,
interception: Interception,
credentials: Registry = .{},
configuration: Configuration,
observations: Observations = undefined,
captures: Producer = undefined,
connection_slots: Slots = .init(service_support.max_connections),
telemetry: Counters = .{},
next_connection_id: std.atomic.Value(u64) = .init(1),
/// The accept loop while the service runs; `stop` joins it.
worker: ?service_support.Worker = null,

/// Builds the loopback listener and every bounded dependency without
/// starting concurrent traffic. Ownership transfers to the returned
/// service on success.
///
/// ```zig
/// const service = try Service.create(io, gpa, paths);
/// defer service.destroy();
/// ```
pub fn create(io: std.Io, gpa: std.mem.Allocator, paths: Paths) !*Service {
    var interception = try Interception.init(io, gpa, paths);
    errdefer interception.deinit();

    var listener = try Listener.bind(io);
    errdefer listener.deinit(io);

    const configuration = try Configuration.init();

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
        .is_live = service_support.observationCredentialIsLive,
    });
    try service.captures.init(gpa, .{
        .config = paths.capture,
        .gate = .{
            .context = service,
            .is_live = service_support.observationCredentialIsLive,
        },
    });

    return service;
}

/// Releases the stopped service and scrubs its in-memory authority and
/// credentials. A started service must be stopped first.
///
/// ```zig
/// service.destroy();
/// ```
pub fn destroy(self: *Service) void {
    std.debug.assert(self.worker == null);
    const gpa = self.gpa;
    self.listener.deinit(self.io);
    self.interception.deinit();
    std.crypto.secureZero(u8, std.mem.asBytes(self));
    gpa.destroy(self);
}

/// Starts the accept loop.
///
/// ```zig
/// try service.start();
/// defer service.stop();
/// ```
pub fn start(self: *Service) !void {
    std.debug.assert(self.worker == null);
    self.worker = try self.io.concurrent(run, .{self});
}

/// Stops traffic, then delivery: joins the accept loop, which cancels every
/// tunnel, and only then closes the observation and capture queues, so no
/// producer outlives them.
///
/// ```zig
/// service.stop();
/// ```
pub fn stop(self: *Service) void {
    if (self.worker) |*worker| {
        _ = worker.cancel(self.io) catch {};
        self.worker = null;
    }

    self.observations.close(self.io);
    self.captures.close(self.io);
}

/// Returns the stable connection and trust configuration inherited by
/// children registered with this service.
///
/// ```zig
/// const client = service.clientConfiguration();
/// ```
pub fn clientConfiguration(self: *const Service) ClientConfiguration {
    const trust = self.interception.clientTrust();

    return .{
        .port = self.listener.port(),
        .certificate_path = trust.certificate_path,
        .bundle_path = trust.bundle_path,
    };
}

fn run(self: *Service) anyerror!void {
    const path = core.enter(.observation);
    defer path.restore();
    try self.configuration.beginServing(self.io);

    return service_support.acceptConnections(self);
}

/// Waits for the next live observation. Events for credentials revoked
/// while queued are discarded before this method returns.
///
/// ```zig
/// var event = try service.receive(io);
/// defer std.crypto.secureZero(u8, &event.credential.token);
/// ```
pub fn receive(self: *Service, io: std.Io) anyerror!MiddlewareEvent {
    return self.observations.receive(io);
}

/// Waits for one captured half whose pane credential remains live.
///
/// ```zig
/// const half = try service.receiveCapture(io);
/// ```
pub fn receiveCapture(self: *Service, io: std.Io) anyerror!*Half {
    return self.captures.receive(io);
}

/// Decodes a captured body outside the traffic relay task.
///
/// ```zig
/// service.decodeCapture(half);
/// ```
pub fn decodeCapture(self: *Service, half: *Half) void {
    self.captures.decodeBody(half);
}

/// Returns one lock-free snapshot without exposing queue, admission, or
/// counter storage to the caller.
///
/// ```zig
/// const snapshot = service.metrics();
/// ```
pub fn metrics(self: *const Service) Snapshot {
    return self.telemetry.snapshot(.{
        .connections = self.connection_slots.snapshot(),
        .observations = self.observations.metrics(),
        .captures = self.captures.metrics(),
    });
}

/// Formats the loopback proxy URL for a credential into caller-owned
/// storage.
///
/// ```zig
/// const url = try service.credentialUrl(&buffer, &credential);
/// ```
pub fn credentialUrl(self: *const Service, buffer: []u8, credential: *const Credential) ![]const u8 {
    return identity.formatUrl(buffer, self.listener.port(), credential);
}

/// Creates and registers a fresh capability for one pane generation. The
/// caller owns the returned secret and must scrub it after use.
///
/// ```zig
/// var credential = try service.registerPane(.{ .id = pane_id, .generation = 2 });
/// defer std.crypto.secureZero(u8, &credential.token);
/// ```
pub fn registerPane(self: *Service, pane: Pane) !Credential {
    var credential: Credential = .{
        .pane_id = pane.id,
        .pane_generation = pane.generation,
        .token = identity.randomToken(self.io),
    };
    errdefer std.crypto.secureZero(u8, &credential.token);

    try self.registerCredential(&credential);

    return credential;
}

fn registerCredential(self: *Service, credential: *const Credential) !void {
    return self.credentials.register(self.io, credential);
}

/// Revokes one exact credential, including rollback of an incomplete pane
/// registration.
///
/// ```zig
/// service.unregisterCredential(&credential);
/// ```
pub fn unregisterCredential(self: *Service, credential: *const Credential) void {
    self.credentials.remove(self.io, credential);
}

/// Revokes every credential issued for one exact pane generation.
///
/// ```zig
/// service.unregisterPane(.{ .id = pane_id, .generation = 2 });
/// ```
pub fn unregisterPane(self: *Service, pane: Pane) void {
    self.credentials.removePane(self.io, .{ .id = pane.id, .generation = pane.generation });
}
