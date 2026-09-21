const std = @import("std");
const core = @import("telar-core");
const Runtime = @import("../Runtime.zig");
const Session = @import("../client/Session.zig");
const requests = @import("../application/requests.zig");
const PendingResponse = @import("../delivery/response_queue.zig").PendingResponse;
const Pane = @import("../../pane/Pane.zig");
const RequestFixture = @This();

temporary: std.testing.TmpDir,
endpoint_buffer: [std.fs.max_path_bytes]u8,
runtime: *Runtime,
session: *Session,
peers: [3]?core.SocketChannel,
peer_count: usize,

/// Keeps runtime state stable and its client writer busy so replies remain inspectable.
/// Example: `var fixture: RequestFixture = undefined; try fixture.init();`.
pub fn init(self: *RequestFixture) !void {
    self.temporary = std.testing.tmpDir(.{});
    errdefer self.temporary.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try self.temporary.dir.realPath(std.testing.io, &directory_buffer)];
    const endpoint = try std.fmt.bufPrint(&self.endpoint_buffer, "{s}/requests.sock", .{directory});
    self.runtime = try std.testing.allocator.create(Runtime);
    errdefer std.testing.allocator.destroy(self.runtime);
    try self.runtime.init(.{
        .dependencies = .{ .io = std.testing.io, .allocator = std.testing.allocator },
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ },
    });
    errdefer self.runtime.deinit();

    self.peers = @splat(null);
    self.peer_count = 0;
    self.session = try self.addClient();
}

/// Adds a real retained connection with its writer held for reply inspection.
/// Example: `const observer = try fixture.addClient();`.
pub fn addClient(self: *RequestFixture) !*Session {
    if (self.peer_count == self.peers.len) {
        return error.FixtureClientLimit;
    }

    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }

    var connection = core.SocketChannel.init(.{ .socket = .{ .handle = sockets[0], .address = .{ .ip4 = .loopback(0) } } });
    errdefer connection.deinit(std.testing.io);
    var peer: core.SocketChannel = .init(.{ .socket = .{ .handle = sockets[1], .address = .{ .ip4 = .loopback(0) } } });
    errdefer peer.deinit(std.testing.io);
    const session = try self.runtime.application.clients.add(std.testing.allocator, connection);
    self.peers[self.peer_count] = peer;
    self.peer_count += 1;
    session.role = .ui;
    session.send_pending = true;
    return session;
}

pub fn deinit(self: *RequestFixture) void {
    self.runtime.deinit();
    std.testing.allocator.destroy(self.runtime);
    for (self.peers[0..self.peer_count]) |*slot| {
        slot.*.?.deinit(std.testing.io);
    }
    self.temporary.cleanup();
}

/// Sends a protocol message through the production dispatch. Example: `try fixture.send(.runtime_stop);`.
pub fn send(self: *RequestFixture, message: core.ClientMessage) !void {
    try self.sendTo(self.session, message);
}

pub fn sendTo(self: *RequestFixture, session: *Session, message: core.ClientMessage) !void {
    try requests.dispatch(&self.runtime.application, session, message);
}

pub fn response(self: *RequestFixture) ?*PendingResponse {
    return self.session.delivery.responses.peek();
}

pub fn clearResponses(self: *RequestFixture) void {
    self.session.delivery.responses.clear();
}

pub fn fillResponses(self: *RequestFixture) !void {
    const queue = &self.session.delivery.responses;
    while (queue.len < queue.items.len) {
        try queue.push(.{ .request_completed = .{ .request_id = .none } });
    }
}

/// Launches a real sleeping child through open_pane and retains its attachment.
/// Example: `const pane = try fixture.openPane();`.
pub fn openPane(self: *RequestFixture) !*Pane {
    var launch_buffer: [64]u8 = undefined;
    try self.send(.{ .open_pane = .{
        .request_id = @enumFromInt(1),
        .target = .default,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = try sleepLaunch(&launch_buffer),
    } });
    const opened = self.response() orelse return error.MissingPaneReply;
    if (opened.* != .pane_opened) {
        return error.PaneLaunchFailed;
    }
    const pane = self.runtime.application.model.panes.find(opened.pane_opened.pane_id).?;
    self.clearResponses();
    return pane;
}

pub fn sleepLaunch(buffer: []u8) !core.LaunchView {
    var encoder = core.Encoder.init(buffer);
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
