//! A running runtime whose clients have caught up with every pane they
//! attach, for timing the delivery flush that ends each runtime update.
//! Benchmarks drive it; the runtime itself never does.

const bytecodec = @import("bytecodec");
const localsocket = @import("localsocket");
const core = @import("telar-core");
const std = @import("std");
const Runtime = @import("Runtime.zig");
const Dependencies = @import("Dependencies.zig");
const Session = @import("client/Session.zig");
const store_support = @import("client/store_support.zig");
const client_delivery = @import("client_delivery.zig");
const client_request = @import("client_request.zig");
const agent_snapshot = @import("agent_snapshot.zig");
const IdleDelivery = @This();

/// Deliveries a fixture drains before it is idle; more means a pane keeps
/// publishing and the fixture would not measure an idle flush.
const max_drain_steps = 4096;

runtime: *Runtime,
dependencies: Dependencies,
endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined,
peers: [store_support.max_clients]?localsocket.SocketChannel = @splat(null),
peer_count: usize = 0,

/// Builds the runtime under `shape.directory`, subscribes every client to
/// runtime state as a TUI or GUI does, attaches it to every pane and drains
/// all initial deliveries. Children are `/bin/sleep`,
/// so no pane publishes afterwards.
///
/// ```zig
/// var idle: IdleDelivery = undefined;
/// try idle.init(.{ .io = io, .allocator = gpa }, .{ .clients = 2, .panes = 8, .directory = path, .environment = environ, .size = size });
/// defer idle.deinit();
/// ```
pub fn init(self: *IdleDelivery, dependencies: Dependencies, shape: Shape) !void {
    std.debug.assert(shape.clients != 0 and shape.clients <= store_support.max_clients);
    std.debug.assert(shape.panes != 0);

    self.* = .{
        .runtime = undefined,
        .dependencies = dependencies,
    };
    const endpoint = try std.fmt.bufPrint(&self.endpoint_buffer, "{s}/idle.sock", .{shape.directory});
    self.runtime = try dependencies.allocator.create(Runtime);
    errdefer dependencies.allocator.destroy(self.runtime);

    try self.runtime.init(.{
        .dependencies = dependencies,
        .options = .{
            .endpoint = endpoint,
            .environment = shape.environment,
        },
    });
    errdefer self.deinitRuntime();

    var sessions: [store_support.max_clients]*Session = undefined;
    for (sessions[0..shape.clients], 1..) |*session, identity| {
        session.* = try self.addClient();
        try client_request.receive(&self.runtime.model, session.*, .{ .request_runtime_state = .{
            .client_identity = @enumFromInt(identity),
        } });
    }

    const first = try self.openDefault(sessions[0], shape.size);
    var panes: [core.max_panes_per_tab]core.PaneId = undefined;
    panes[0] = first.pane_id;
    for (panes[1..shape.panes]) |*pane_id| {
        pane_id.* = try self.split(sessions[0], first.location, shape.size);
    }

    for (sessions[1..shape.clients]) |session| {
        for (panes[0..shape.panes]) |pane_id| {
            try self.openPane(session, pane_id, shape.size);
        }
    }

    for (sessions[0..shape.clients]) |session| {
        try self.drain(session);
        session.send_pending = false;
    }
}

/// Runs the flush every runtime update ends with.
///
/// ```zig
/// try idle.flush();
/// ```
pub fn flush(self: *IdleDelivery) !void {
    try client_delivery.flush(&self.runtime.model);
}

/// Reports whether every client is still idle: no flush started a write.
///
/// ```zig
/// std.debug.assert(idle.quiet());
/// ```
pub fn quiet(self: *const IdleDelivery) bool {
    for (self.runtime.model.clients.items) |slot| {
        const session = slot orelse continue;
        if (session.send_pending) {
            return false;
        }
    }

    return true;
}

/// Example: `idle.deinit();`.
pub fn deinit(self: *IdleDelivery) void {
    self.deinitRuntime();
    for (self.peers[0..self.peer_count]) |*slot| {
        slot.*.?.deinit(self.dependencies.io);
    }
}

fn deinitRuntime(self: *IdleDelivery) void {
    self.runtime.deinit();
    self.dependencies.allocator.destroy(self.runtime);
}

fn addClient(self: *IdleDelivery) !*Session {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }

    var connection = localsocket.SocketChannel.init(.{ .socket = .{ .handle = sockets[0], .address = .{ .ip4 = .loopback(0) } } });
    errdefer connection.deinit(self.dependencies.io);
    var peer: localsocket.SocketChannel = .init(.{ .socket = .{ .handle = sockets[1], .address = .{ .ip4 = .loopback(0) } } });
    errdefer peer.deinit(self.dependencies.io);

    const session = try self.runtime.model.clients.add(self.dependencies.allocator, connection);
    self.peers[self.peer_count] = peer;
    self.peer_count += 1;
    session.role = .ui;
    session.send_pending = true;
    return session;
}

fn openDefault(self: *IdleDelivery, session: *Session, size: core.TerminalSize) !core.PaneOpened {
    var launch_buffer: [launch_bytes]u8 = undefined;
    try client_request.receive(&self.runtime.model, session, .{ .open_pane = .{
        .request_id = @enumFromInt(1),
        .target = .default,
        .size = size,
        .launch = try sleepLaunch(&launch_buffer),
    } });

    return takeOpened(session);
}

fn split(self: *IdleDelivery, session: *Session, location: core.TabLocation, size: core.TerminalSize) !core.PaneId {
    var launch_buffer: [launch_bytes]u8 = undefined;
    try client_request.receive(&self.runtime.model, session, .{ .create_pane = .{
        .request_id = @enumFromInt(1),
        .location = location,
        .size = size,
        .launch = try sleepLaunch(&launch_buffer),
    } });

    const opened = try takeOpened(session);
    return opened.pane_id;
}

fn openPane(self: *IdleDelivery, session: *Session, pane_id: core.PaneId, size: core.TerminalSize) !void {
    try client_request.receive(&self.runtime.model, session, .{ .open_pane = .{
        .request_id = @enumFromInt(1),
        .target = .{ .pane = pane_id },
        .size = size,
        .launch = null,
    } });

    _ = try takeOpened(session);
}

/// Commits every pending delivery as if the write succeeded and the client
/// acknowledged each frame, until the client has nothing left to receive.
/// Sources are prepared as `client_delivery.flush` prepares them.
fn drain(self: *IdleDelivery, session: *Session) !void {
    const model = &self.runtime.model;
    for (0..max_drain_steps) |_| {
        acknowledgeFrames(self, session);
        agent_snapshot.refresh(model);
        var sources = client_delivery.deliverySources(model);
        if (agent_snapshot.wanted(model)) {
            sources.agent_entries = agent_snapshot.project(sources, &model.agent_entries, &model.agent_display);
        }

        const prepared = try session.delivery.prepare(.{
            .io = model.io,
            .attachments = &model.attachments,
            .client = session.slot,
            .sources = sources,
            .metrics = &model.metrics,
        }) orelse return;

        session.delivery.commit(.{
            .prepared = prepared,
            .attachments = &model.attachments,
            .client = session.slot,
            .metrics = &model.metrics,
        });
        _ = session.delivery.complete({});
    }

    return error.DeliveryNeverSettled;
}

fn acknowledgeFrames(self: *IdleDelivery, session: *Session) void {
    for (&self.runtime.model.attachments.record[session.slot]) |slot| {
        const attachment = slot orelse continue;
        const frame_id = attachment.outstandingFrameId();
        if (frame_id != 0) {
            _ = attachment.acknowledgeFrame(frame_id, 0);
        }
    }
}

fn takeOpened(session: *Session) !core.PaneOpened {
    const pending = session.delivery.responses.peek() orelse return error.MissingResponse;
    defer session.delivery.responses.clear();

    return switch (pending.*) {
        .pane_opened => |opened| opened,
        else => error.UnexpectedResponse,
    };
}

/// Bytes an encoded `/bin/sleep 600` launch needs.
const launch_bytes = 64;

fn sleepLaunch(buffer: []u8) !core.LaunchView {
    var encoder = bytecodec.Encoder.init(buffer);
    try encoder.writeSized16("/bin/sleep");
    try encoder.writeSized16("600");
    return .{
        .cwd = "/",
        .argument_count = 2,
        .encoded_arguments = encoder.finish(),
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    };
}

const Shape = struct {
    clients: usize,
    panes: usize,
    /// An existing directory the runtime's socket lives in.
    directory: []const u8,
    environment: std.process.Environ,
    size: core.TerminalSize,
};
