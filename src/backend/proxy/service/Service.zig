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
const TunnelJoin = @import("TunnelJoin.zig").TunnelJoin;
const TunnelTestGate = @import("TunnelTestGate.zig");
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
/// Every admitted connection's tunnel. The accept loop adds them; the
/// reaper cancels them when the service stops.
tunnels: std.Io.Group = .init,
/// Set by `stop` to end the reaper's rounds.
stopping: std.Io.Event = .unset,
/// Set by the reaper once every tunnel returned.
tunnels_joined: std.Io.Event = .unset,
/// Test seam: holds a tunnel in a wait no cancellation interrupts.
tunnel_gate: ?*TunnelTestGate,
/// The accept loop while the service runs; `stop` joins it.
worker: ?service_support.Worker = null,
/// The loop that closes connections past their deadlines and, when the
/// service stops, cancels every tunnel and waits for them. `stop` joins it
/// once they returned.
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
        .tunnel_gate = paths.tunnel_gate,
    };
    try service.captures.init(gpa, paths.capture);

    return service;
}

/// Releases the stopped service and scrubs its in-memory authority and
/// secret. A started service must be stopped first, and `stop` must have
/// joined every tunnel: one still running uses this memory.
///
/// ```zig
/// service.destroy();
/// ```
pub fn destroy(self: *Service) void {
    std.debug.assert(self.worker == null and self.reaper == null);
    const gpa = self.gpa;
    self.listener.deinit(self.io);
    self.interception.deinit();
    std.crypto.secureZero(u8, std.mem.asBytes(self));
    gpa.destroy(self);
}

/// Starts the reaper, then the accept loop.
///
/// ```zig
/// try service.start();
/// defer _ = service.stop();
/// ```
pub fn start(self: *Service) !void {
    std.debug.assert(self.worker == null and self.reaper == null);
    self.reaper = try self.io.concurrent(reap, .{self});
    errdefer _ = self.stop();

    self.worker = try self.io.concurrent(run, .{self});
}

/// Stops traffic and says whether every tunnel returned. It joins the
/// accept loop and closes the listening socket, so the port is free from
/// here on whatever the tunnels do; shuts every connection's sockets down
/// and cancels its tunnel; then waits for the tunnels at most
/// `service_support.stop_timeout_ms`.
///
/// `.joined`: no tunnel is left, the capture queue is closed so no producer
/// outlives it, and `destroy` may follow. `.abandoned`: a tunnel is still
/// inside a call that neither a shutdown nor a cancellation interrupts,
/// such as the system resolver. Its thread still uses the service, so the
/// service must not be destroyed; calling `stop` again waits again.
///
/// ```zig
/// if (service.stop() == .joined) {
///     service.destroy();
/// }
/// ```
pub fn stop(self: *Service) TunnelJoin {
    if (self.worker) |*worker| {
        _ = worker.cancel(self.io) catch {};
        self.worker = null;
    }

    self.listener.deinit(self.io);

    if (self.reaper) |*reaper| {
        self.connections.shutDownAll();
        self.stopping.set(self.io);
        if (!service_support.awaitTunnels(self)) {
            return .abandoned;
        }

        _ = reaper.await(self.io) catch {};
        self.reaper = null;
    }

    self.captures.close(self.io);
    return .joined;
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

    return service_support.reapConnections(self);
}

/// Waits for one captured half and, when `decode` asks, decodes its body.
/// It runs on the task that waits, off the runtime's event loop and off
/// every relay task, so decompression delays neither keystrokes nor
/// traffic.
///
/// ```zig
/// const half = try service.receiveCapture(io, true);
/// ```
pub fn receiveCapture(self: *Service, io: std.Io, decode: bool) anyerror!*Half {
    const half = try self.captures.receive(io);
    if (decode) {
        self.captures.decodeBody(half);
    }

    return half;
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
