//! Socket admission and send completion contracts through Runtime.update.
const std = @import("std");
const core = @import("telar-core");
const ClientKey = @import("../../history/ClientKey.zig");
const RequestFixture = @import("RequestFixture.zig");
const client_delivery = @import("../client_delivery.zig");

fn socketPair() ![2]core.SocketChannel {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }

    return .{
        .init(.{ .socket = .{ .handle = sockets[0], .address = .{ .ip4 = .loopback(0) } } }),
        .init(.{ .socket = .{ .handle = sockets[1], .address = .{ .ip4 = .loopback(0) } } }),
    };
}

fn expectPeerClosed(peer: *core.SocketChannel) !void {
    var byte: [1]u8 = undefined;
    const received = std.c.recv(peer.stream.socket.handle, &byte, byte.len, std.c.MSG.DONTWAIT);
    try std.testing.expectEqual(@as(isize, 0), received);
}

fn commitQueuedResponse(fixture: *RequestFixture) !void {
    const model = &fixture.runtime.model;
    const session = fixture.session;
    try session.delivery.responses.push(.{ .request_completed = .{ .request_id = @enumFromInt(41) } });
    const prepared = (try session.delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &session.attachments,
        .sources = .{
            .panes = &model.panes,
            .workspaces = &model.workspaces,
            .agents = &model.agents,
            .system_metrics = &model.system_metrics,
            .proxy_active = false,
            .home = null,
        },
        .metrics = &model.metrics,
    })).?;
    session.delivery.commit(.{
        .prepared = prepared,
        .attachments = &session.attachments,
        .metrics = &model.metrics,
    });
}

test "runtime update releases a rejected handshake slot and closes its exact socket" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var sockets = try socketPair();
    defer sockets[1].deinit(std.testing.io);
    const clients_before = fixture.runtime.model.clients.count;
    fixture.runtime.model.client_admission.begin(sockets[0]);

    try std.testing.expect(!try fixture.runtime.update(.{ .handshaken = error.IncompatibleProtocol }));
    try std.testing.expect(!fixture.runtime.model.client_admission.isPending());
    try std.testing.expectEqual(clients_before, fixture.runtime.model.clients.count);
    try expectPeerClosed(&sockets[1]);
}

test "runtime update refuses completed negotiation after shutdown starts" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var sockets = try socketPair();
    defer sockets[1].deinit(std.testing.io);
    const clients_before = fixture.runtime.model.clients.count;
    fixture.runtime.model.client_admission.begin(sockets[0]);
    try fixture.send(.runtime_stop);

    try std.testing.expect(!try fixture.runtime.update(.{ .handshaken = {} }));
    try std.testing.expect(!fixture.runtime.model.client_admission.isPending());
    try std.testing.expectEqual(clients_before, fixture.runtime.model.clients.count);
    try expectPeerClosed(&sockets[1]);
}

test "runtime update closes a negotiated socket when client identities are exhausted" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var sockets = try socketPair();
    defer sockets[1].deinit(std.testing.io);
    const clients_before = fixture.runtime.model.clients.count;
    fixture.runtime.model.client_admission.begin(sockets[0]);
    fixture.runtime.model.clients.next_id = std.math.maxInt(u64);

    try std.testing.expect(!try fixture.runtime.update(.{ .handshaken = {} }));
    try std.testing.expect(!fixture.runtime.model.client_admission.isPending());
    try std.testing.expectEqual(clients_before, fixture.runtime.model.clients.count);
    try std.testing.expect(fixture.runtime.model.clients.resolve(fixture.session.key) == fixture.session);
    try expectPeerClosed(&sockets[1]);
}

test "runtime update transfers a negotiated connection before starting its first read" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var sockets = try socketPair();
    defer sockets[1].deinit(std.testing.io);
    const clients = &fixture.runtime.model.clients;
    const expected_key: ClientKey = .{ .id = clients.next_id, .generation = clients.next_generation };
    const admitted_fd = sockets[0].stream.socket.handle;
    fixture.runtime.model.client_admission.begin(sockets[0]);

    try std.testing.expect(!try fixture.runtime.update(.{ .handshaken = {} }));
    try std.testing.expect(!fixture.runtime.model.client_admission.isPending());
    const admitted = clients.resolve(expected_key).?;
    try std.testing.expectEqual(admitted_fd, admitted.connection.stream.socket.handle);
    try std.testing.expect(admitted.read_pending);
    try std.testing.expectEqual(.undecided, admitted.role);
    try std.testing.expect(admitted.active());
    try std.testing.expectEqual(@as(usize, 2), clients.count);
}

test "runtime update closes accepted sockets while shutdown owns the runtime" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var sockets = try socketPair();
    defer sockets[1].deinit(std.testing.io);
    try fixture.send(.runtime_stop);
    const clients_before = fixture.runtime.model.clients.count;

    try std.testing.expect(!try fixture.runtime.update(.{ .accepted = sockets[0] }));
    try std.testing.expect(!fixture.runtime.model.client_admission.isPending());
    try std.testing.expectEqual(clients_before, fixture.runtime.model.clients.count);
    try expectPeerClosed(&sockets[1]);
}

test "runtime update interrupts a stalled handshake without replacing its borrowed slot" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stalled = try socketPair();
    defer stalled[1].deinit(std.testing.io);
    var incoming = try socketPair();
    defer incoming[1].deinit(std.testing.io);
    const borrowed_fd = stalled[0].stream.socket.handle;
    fixture.runtime.model.client_admission.begin(stalled[0]);

    try std.testing.expect(!try fixture.runtime.update(.{ .accepted = incoming[0] }));
    try std.testing.expect(fixture.runtime.model.client_admission.isPending());
    try std.testing.expectEqual(borrowed_fd, fixture.runtime.model.client_admission.pendingConnection().?.stream.socket.handle);
    try expectPeerClosed(&incoming[1]);
    try expectPeerClosed(&stalled[1]);

    try std.testing.expect(!try fixture.runtime.update(.{ .handshaken = error.ConnectionClosed }));
    try std.testing.expect(!fixture.runtime.model.client_admission.isPending());
}

test "runtime update closes a one-shot client only after its reply write completes" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const key = fixture.session.key;
    fixture.session.delivery.setCloseAfterReply(true);
    try commitQueuedResponse(&fixture);
    try std.testing.expect(fixture.runtime.model.clients.resolve(key) != null);

    try std.testing.expect(!try fixture.runtime.update(.{ .client_sent = .{ .client = key, .result = {} } }));
    try std.testing.expect(fixture.runtime.model.clients.resolve(key) == null);
    try expectPeerClosed(&fixture.peers[0].?);
}

test "runtime update releases and closes an active client after a failed reply write" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const key = fixture.session.key;
    try commitQueuedResponse(&fixture);
    try std.testing.expect(!fixture.session.closing);

    try std.testing.expect(!try fixture.runtime.update(.{ .client_sent = .{ .client = key, .result = error.BrokenPipe } }));
    try std.testing.expect(fixture.runtime.model.clients.resolve(key) == null);
    try expectPeerClosed(&fixture.peers[0].?);
}

test "runtime update defers pane detachment until its exit publication is written" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const initial_output_done = pane.output_done;
    const initial_render_pending = pane.render_pending;
    pane.exit = .{ .exited = 0 };
    pane.output_done = true;
    pane.render_pending = false;
    defer {
        pane.exit = null;
        pane.output_done = initial_output_done;
        pane.render_pending = initial_render_pending;
    }
    const session = fixture.session;
    const attachment = session.attachments.find(pane.id).?;
    attachment.cells.snapshot_pending = false;
    attachment.cells.observed_revision = pane.cell_revision;
    const publication = (try attachment.prepareExit(session.delivery.send_buffer)).?;
    const prepared = session.delivery.stage(publication.bytes, .{ .attachment = .{
        .index = session.attachments.index.get(core.raw(pane.id)).?,
        .prepared = publication,
    } });
    session.delivery.commit(.{
        .prepared = prepared,
        .attachments = &session.attachments,
        .metrics = &fixture.runtime.model.metrics,
    });
    try std.testing.expect(attachment.exit_sent);
    try std.testing.expect(session.attachments.find(pane.id) != null);

    try std.testing.expect(!try fixture.runtime.update(.{ .client_sent = .{ .client = session.key, .result = {} } }));
    try std.testing.expect(session.attachments.find(pane.id) == null);
    try std.testing.expectEqual(@as(usize, 0), session.attachments.count);
    try std.testing.expect(!session.send_pending);
    try std.testing.expect(session.active());
}

test "runtime update delivers shutdown before retiring a one-shot client" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const key = fixture.session.key;
    fixture.session.delivery.setCloseAfterReply(true);
    try commitQueuedResponse(&fixture);
    try fixture.send(.runtime_stop);

    try std.testing.expect(!try fixture.runtime.update(.{ .client_sent = .{ .client = key, .result = {} } }));
    try std.testing.expect(fixture.runtime.model.clients.resolve(key) != null);
    try std.testing.expect(fixture.session.send_pending);
    var response: [16]u8 = undefined;
    const bytes = try fixture.peers[0].?.receive(std.testing.io, &response);
    try std.testing.expect(try core.decodeServer(bytes) == .runtime_stopping);

    while (true) {
        const event = try fixture.runtime.loop.next();
        const stopped = try fixture.runtime.update(event);
        if (event == .client_sent) {
            try std.testing.expectEqualDeep(key, event.client_sent.client);
            try std.testing.expect(stopped);
            break;
        }
    }
    try std.testing.expect(!fixture.session.send_pending);
    try std.testing.expect(client_delivery.shutdownDelivered(&fixture.runtime.model));
}

test "runtime update delivers a workspace resync to other observers in the same update" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const observer = try fixture.addClient();
    _ = try observer.attachments.attach(fixture.runtime.model.gpa, pane);
    observer.send_pending = false;

    var wire: [64]u8 = undefined;
    const encoded = try core.encodeRenameTab(&wire, .{
        .request_id = @enumFromInt(41),
        .location = pane.location,
        .label = "logs",
    });

    try std.testing.expect(!try fixture.runtime.update(.{ .client_message = .{
        .client = fixture.session.key,
        .result = wire[0..encoded.len],
    } }));

    try std.testing.expect(observer.delivery.responses.resync_workspace == null);
    try std.testing.expect(observer.send_pending);
    var response: [256]u8 = undefined;
    const bytes = try fixture.peers[1].?.receive(std.testing.io, &response);
    const delivered = try core.decodeServer(bytes);
    try std.testing.expect(delivered == .resync_required);
    try std.testing.expectEqualDeep(pane.location.workspace, delivered.resync_required.workspace);
}
