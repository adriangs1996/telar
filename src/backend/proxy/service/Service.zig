const owned = @import("../capture/owned.zig");
const core = @import("telar-core");
const std = @import("std");
const Listener = @import("Listener.zig");
const Interception = @import("Interception.zig");
const Producer = @import("../capture/Producer.zig");
const Connections = @import("../Connections.zig");
const service_support = @import("service_support.zig");
const Counters = @import("../Counters.zig");
const Paths = @import("Paths.zig");
const ClientConfiguration = @import("ClientConfiguration.zig");
const Half = owned.Half;
const Snapshot = @import("../Snapshot.zig");
const identity = @import("../identity.zig");
const secret_store = @import("secret.zig");
const PortMemory = @import("PortMemory.zig");
const Service = @This();

io: std.Io,
gpa: std.mem.Allocator,
listener: Listener,
interception: Interception,
/// The one secret every child of this runtime authenticates with.
secret: identity.Secret,
/// The port this runtime tried first; null when it remembered none. A
/// bound port that differs means another process held this one.
preferred_port: ?u16,
captures: Producer = undefined,
connections: Connections = .{},
telemetry: Counters = .{},
next_connection_id: std.atomic.Value(u64) = .init(1),
/// The accept loop while the service runs; `stop` joins it.
worker: ?service_support.Worker = null,
/// The loop that closes connections past their deadlines; `stop` joins it.
reaper: ?service_support.Worker = null,

/// Builds the loopback listener and every bounded dependency without
/// starting concurrent traffic: the secret is read or created, and the
/// listener prefers the port this runtime remembered from its last start
/// and avoids the ports other runtimes remember. Ownership
/// transfers to the returned service on success.
///
/// ```zig
/// const service = try Service.create(io, gpa, paths);
/// defer service.destroy();
/// ```
pub fn create(io: std.Io, gpa: std.mem.Allocator, paths: Paths) !*Service {
    service_support.raiseDescriptorLimit();

    var interception = try Interception.init(io, gpa, paths);
    errdefer interception.deinit();

    var secret = try secret_store.ensure(io, paths.secret);
    defer std.crypto.secureZero(u8, &secret);

    const memory = PortMemory.load(io, paths);
    var listener = try Listener.bind(io, memory.preferred(), &memory.reserved);
    errdefer listener.deinit(io);
    memory.remember(io, paths, listener.port());

    const service = try gpa.create(Service);
    errdefer gpa.destroy(service);
    service.* = .{
        .io = io,
        .gpa = gpa,
        .listener = listener,
        .interception = interception,
        .secret = secret,
        .preferred_port = memory.preferred(),
    };
    try service.captures.init(gpa, paths.capture);

    return service;
}

/// Releases the stopped service and scrubs its in-memory authority and
/// secret. A started service must be stopped first.
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
    errdefer self.stop();

    self.reaper = try self.io.concurrent(reap, .{self});
}

/// Stops traffic, then delivery: joins the accept loop, which cancels every
/// tunnel, and only then closes the capture queue, so no producer outlives
/// it.
///
/// ```zig
/// service.stop();
/// ```
pub fn stop(self: *Service) void {
    if (self.reaper) |*reaper| {
        _ = reaper.cancel(self.io) catch {};
        self.reaper = null;
    }

    if (self.worker) |*worker| {
        _ = worker.cancel(self.io) catch {};
        self.worker = null;
    }

    self.captures.close(self.io);
}

/// Returns the stable connection and trust configuration inherited by
/// children of this runtime.
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

    return service_support.acceptConnections(self);
}

fn reap(self: *Service) anyerror!void {
    const path = core.enter(.observation);
    defer path.restore();

    return service_support.expireConnections(self);
}

/// Waits for one captured half.
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

/// Returns one lock-free snapshot without exposing admission or counter
/// storage to the caller.
///
/// ```zig
/// const snapshot = service.metrics();
/// ```
pub fn metrics(self: *const Service) Snapshot {
    return self.telemetry.snapshot(.{
        .connections = self.connections.snapshot(),
        .captures = self.captures.metrics(),
    });
}

/// Formats the loopback proxy URL carrying the secret into caller-owned
/// storage, which the caller scrubs after use.
///
/// ```zig
/// const url = try service.proxyUrl(&buffer);
/// ```
pub fn proxyUrl(self: *const Service, buffer: []u8) ![]const u8 {
    return identity.formatUrl(buffer, self.listener.port(), &self.secret);
}
