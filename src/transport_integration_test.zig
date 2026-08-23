const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const handshake = core.schema.handshake;

const HandshakeWorker = struct {
    io: std.Io,
    connection: *core.transport.SocketChannel,
    supported: handshake.VersionRange,
    response: ?handshake.ServerResponse = null,
    failure: ?anyerror = null,

    fn run(worker: *@This()) void {
        worker.response = backend.transport.handshake.performVersions(
            worker.io,
            worker.connection,
            worker.supported,
        ) catch |err| {
            worker.failure = err;
            return;
        };
    }
};

test "frontend and backend exchange framed messages over a local socket" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/transport.sock", .{directory});

    var listener = try backend.transport.local.LocalListener.listen(io, path);
    defer listener.deinit(io);

    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.unix_domain_socket, stat.kind);
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);

    var client = try frontend.transport.local.connect(io, path);
    defer client.deinit(io);
    var peer = try listener.accept(io);
    defer peer.deinit(io);

    try client.send(io, "hello from frontend");
    var request_buffer: [64]u8 = undefined;
    const request = try peer.receive(io, &request_buffer);
    try std.testing.expectEqualStrings("hello from frontend", request);

    try peer.send(io, "hello from backend");
    var response_buffer: [64]u8 = undefined;
    const response = try client.receive(io, &response_buffer);
    try std.testing.expectEqualStrings("hello from backend", response);

    listener.deinit(io);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }),
    );
}

test "a second backend cannot replace a live endpoint" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/transport.sock", .{directory});

    var listener = try backend.transport.local.LocalListener.listen(io, path);
    defer listener.deinit(io);

    try std.testing.expectError(
        error.AddressInUse,
        backend.transport.local.LocalListener.listen(io, path),
    );

    var client = try frontend.transport.local.connect(io, path);
    client.deinit(io);
}

test "frontend and backend negotiate the highest shared protocol version" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/handshake.sock", .{directory});

    var listener = try backend.transport.local.LocalListener.listen(io, path);
    defer listener.deinit(io);
    var client = try frontend.transport.local.connect(io, path);
    defer client.deinit(io);
    var peer = try listener.accept(io);
    defer peer.deinit(io);

    var worker = HandshakeWorker{
        .io = io,
        .connection = &peer,
        .supported = .{ .minimum = 2, .maximum = 4 },
    };
    const thread = try std.Thread.spawn(.{}, HandshakeWorker.run, .{&worker});
    const client_response = try frontend.transport.handshake.performVersions(
        io,
        &client,
        .{ .minimum = 1, .maximum = 3 },
    );
    thread.join();

    if (worker.failure) |err| return err;
    try std.testing.expectEqual(@as(handshake.Version, 3), client_response.accepted.version);
    try std.testing.expectEqualDeep(client_response, worker.response.?);
}

test "backend explains incompatible protocol versions" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/handshake.sock", .{directory});

    var listener = try backend.transport.local.LocalListener.listen(io, path);
    defer listener.deinit(io);
    var client = try frontend.transport.local.connect(io, path);
    defer client.deinit(io);
    var peer = try listener.accept(io);
    defer peer.deinit(io);

    const server_versions = handshake.VersionRange{ .minimum = 1, .maximum = 1 };
    var worker = HandshakeWorker{
        .io = io,
        .connection = &peer,
        .supported = server_versions,
    };
    const thread = try std.Thread.spawn(.{}, HandshakeWorker.run, .{&worker});
    const client_response = try frontend.transport.handshake.performVersions(
        io,
        &client,
        .{ .minimum = 2, .maximum = 2 },
    );
    thread.join();

    if (worker.failure) |err| return err;
    try std.testing.expectEqual(
        handshake.RejectReason.incompatible_versions,
        client_response.rejected.reason,
    );
    try std.testing.expectEqual(server_versions, client_response.rejected.supported_versions);
    try std.testing.expectEqualDeep(client_response, worker.response.?);
}

test "runtime stops with a live pane and removes its endpoint" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/stoppable.sock",
        .{directory_buffer[0..directory_len]},
    );

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntil, .{ io, gpa, path, &stop });
    var server_finished = false;
    defer if (!server_finished) {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    };

    var primary = try connectRuntimeForTest(io, path);
    defer primary.deinit(io);
    var send_buffer: [512]u8 = undefined;
    const arguments = [_][]const u8{ "/bin/sleep", "600" };
    try primary.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory_buffer[0..directory_len], .arguments = &arguments },
    }));

    var receive_buffer: [4096]u8 = undefined;
    while (true) {
        switch (try schema.decodeServer(try primary.receive(io, &receive_buffer))) {
            .pane_opened => break,
            .request_failed => return error.RuntimeRequestFailed,
            .runtime_stopping => return error.UnexpectedRuntimeShutdown,
            else => {},
        }
    }

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);
    try connection.send(io, try schema.encodeRuntimeStop(&send_buffer));

    try std.testing.expect(
        (try schema.decodeServer(try connection.receive(io, &receive_buffer))) == .runtime_stopping,
    );

    while (true) {
        switch (try schema.decodeServer(try primary.receive(io, &receive_buffer))) {
            .runtime_stopping => break,
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }

    try server.await(io);
    server_finished = true;
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }),
    );
}

test "runtime destroys a pane after its shell exits" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/runtime.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntil, .{ io, gpa, path, &stop });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var client: ?core.transport.SocketChannel = null;
    for (0..200) |_| {
        client = frontend.transport.local.connect(io, path) catch null;
        if (client != null) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    var connection = client orelse return error.RuntimeDidNotStart;
    defer connection.deinit(io);

    const negotiated = try frontend.transport.handshake.perform(io, &connection);
    try std.testing.expect(negotiated == .accepted);

    const arguments = [_][]const u8{
        "/bin/sh",
        "-c",
        "IFS= read -r line; printf %s \"$line\"; exit 7",
    };
    var send_buffer: [512]u8 = undefined;
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    var cells: [40 * 8]core.ui.Cell = @splat(.{});
    var pane_id: schema.PaneId = .invalid;
    var location: ?schema.TabLocation = null;
    var saw_output = false;
    var saw_exit = false;
    var rejected_reattach = false;
    var saw_empty_location = false;

    for (0..96) |_| {
        const payload = try connection.receive(io, receive_buffer);
        switch (try schema.decodeServer(payload)) {
            .pane_opened => |opened| {
                if (saw_exit) return error.ExitedPaneReattached;
                pane_id = opened.pane_id;
                location = opened.location;
                try connection.send(io, try schema.encodePaneInput(&send_buffer, .{
                    .pane_id = pane_id,
                    .bytes = "TELAR_RUNTIME_E2E\n",
                }));
            },
            .pane_frame => |frame| {
                var spans = frame.spans();
                while (spans.next()) |span| {
                    var frame_cells = span.cells();
                    var index: usize = span.start;
                    while (frame_cells.next()) |cell| : (index += 1) cells[index] = cell;
                }
                saw_output = rowContains(cells[0..40], "TELAR_RUNTIME_E2E");
                try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
                    .pane_id = pane_id,
                    .frame_id = frame.frame_id,
                }));
            },
            .pane_exited => |exited| {
                try std.testing.expect(saw_output);
                try std.testing.expectEqual(schema.ExitKind.exited, exited.kind);
                try std.testing.expectEqual(@as(u32, 7), exited.value);
                saw_exit = true;
                try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
                    .request_id = @enumFromInt(2),
                    .target = .{ .pane = pane_id },
                    .size = .{ .cols = 40, .rows = 8 },
                    .launch = null,
                }));
                try connection.send(io, try schema.encodeRequestTabSnapshot(&send_buffer, .{
                    .request_id = @enumFromInt(3),
                    .location = location.?,
                }));
            },
            .request_failed => |failure| {
                if (failure.request_id != @as(schema.RequestId, @enumFromInt(2))) {
                    std.debug.print("runtime integration failure: {s}\n", .{failure.message});
                    return error.RuntimeRequestFailed;
                }
                try std.testing.expectEqual(schema.FailureCode.pane_not_found, failure.code);
                rejected_reattach = true;
            },
            .runtime_stopping => return error.UnexpectedRuntimeShutdown,
            .tab_snapshot => |snapshot| {
                try std.testing.expectEqual(
                    @as(schema.RequestId, @enumFromInt(3)),
                    snapshot.request_id,
                );
                try std.testing.expectEqual(@as(u16, 0), snapshot.pane_count);
                saw_empty_location = true;
            },
            .history_results => return error.UnexpectedHistoryResults,
            else => return error.UnexpectedTabMessage,
        }
        if (saw_exit and rejected_reattach and saw_empty_location) return;
    }
    return error.RuntimeDidNotExit;
}

test "one client drives two attached panes and closes either one" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/multi-pane.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntil, .{ io, gpa, path, &stop });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);
    var send_buffer: [1024]u8 = undefined;
    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);

    const first_arguments = [_][]const u8{
        "/bin/sh",
        "-c",
        "IFS= read -r line; printf 'FIRST:%s' \"$line\"; sleep 600",
    };
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &first_arguments },
    }));

    var first_id: schema.PaneId = .invalid;
    var location: schema.TabLocation = undefined;
    while (first_id == .invalid) {
        switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
            .pane_opened => |opened| {
                first_id = opened.pane_id;
                location = opened.location;
            },
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }

    const second_arguments = [_][]const u8{
        "/bin/sh",
        "-c",
        "IFS= read -r line; printf 'SECOND:%s' \"$line\"; sleep 600",
    };
    try connection.send(io, try schema.encodeCreatePane(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .location = location,
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &second_arguments },
    }));

    var second_id: schema.PaneId = .invalid;
    while (second_id == .invalid) {
        switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
            .pane_opened => |opened| if (opened.request_id == @as(schema.RequestId, @enumFromInt(2))) {
                second_id = opened.pane_id;
            },
            .pane_frame => |frame| try connection.send(io, try schema.encodeFrameAck(
                &send_buffer,
                .{ .pane_id = frame.pane_id, .frame_id = frame.frame_id },
            )),
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }
    try std.testing.expect(first_id != second_id);

    try connection.send(io, try schema.encodePaneInput(&send_buffer, .{
        .pane_id = first_id,
        .bytes = "one\n",
    }));
    try connection.send(io, try schema.encodePaneInput(&send_buffer, .{
        .pane_id = second_id,
        .bytes = "two\n",
    }));

    var first_cells: [40 * 8]core.ui.Cell = @splat(.{});
    var second_cells: [40 * 8]core.ui.Cell = @splat(.{});
    var saw_first = false;
    var saw_second = false;
    var close_sent = false;
    var saw_second_exit = false;
    for (0..256) |_| {
        switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
            .pane_frame => |frame| {
                const cells = if (frame.pane_id == first_id)
                    first_cells[0..]
                else if (frame.pane_id == second_id)
                    second_cells[0..]
                else
                    return error.UnexpectedPane;
                applyFrameCells(cells, frame);
                saw_first = rowContains(&first_cells, "FIRST:one");
                saw_second = rowContains(&second_cells, "SECOND:two");
                try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
                    .pane_id = frame.pane_id,
                    .frame_id = frame.frame_id,
                }));
                if (saw_first and saw_second and !close_sent) {
                    close_sent = true;
                    try connection.send(io, try schema.encodeClosePane(&send_buffer, .{
                        .request_id = @enumFromInt(3),
                        .pane_id = second_id,
                    }));
                }
            },
            .pane_exited => |exited| {
                if (exited.pane_id != second_id) return error.UnexpectedPaneExit;
                saw_second_exit = true;
                break;
            },
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }
    try std.testing.expect(saw_first);
    try std.testing.expect(saw_second);
    try std.testing.expect(saw_second_exit);

    try connection.send(io, try schema.encodeRequestTabSnapshot(&send_buffer, .{
        .request_id = @enumFromInt(4),
        .location = location,
    }));
    while (true) {
        switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
            .tab_snapshot => |snapshot| {
                try std.testing.expectEqual(@as(u16, 1), snapshot.pane_count);
                var panes = snapshot.panes();
                try std.testing.expectEqual(first_id, panes.next().?.pane_id);
                return;
            },
            .pane_frame => |frame| try connection.send(io, try schema.encodeFrameAck(
                &send_buffer,
                .{ .pane_id = frame.pane_id, .frame_id = frame.frame_id },
            )),
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }
}

test "pane keeps running while its client is disconnected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/persistent.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntil, .{ io, gpa, path, &stop });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var first = try connectRuntimeForTest(io, path);
    const arguments = [_][]const u8{
        "/bin/sh",
        "-c",
        "sleep 1; printf TELAR_PERSISTED; exit 0",
    };
    var send_buffer: [512]u8 = undefined;
    try first.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    var original_pane_id: schema.PaneId = .invalid;
    while (original_pane_id == .invalid) {
        switch (try schema.decodeServer(try first.receive(io, receive_buffer))) {
            .pane_opened => |opened| original_pane_id = opened.pane_id,
            .request_failed => return error.RuntimeRequestFailed,
            .runtime_stopping => return error.UnexpectedRuntimeShutdown,
            .tab_snapshot => return error.UnexpectedTabSnapshot,
            else => {},
        }
    }
    first.deinit(io);

    try io.sleep(.fromMilliseconds(200), .awake);
    var second = try connectRuntimeForTest(io, path);
    defer second.deinit(io);
    try second.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{"/bin/false"} },
    }));

    var cells: [40 * 8]core.ui.Cell = @splat(.{});
    var saw_output = false;
    var attached = false;
    for (0..64) |_| {
        const payload = second.receive(io, receive_buffer) catch |err| {
            std.debug.print("reconnected client receive failed: {s}\n", .{@errorName(err)});
            return err;
        };
        switch (try schema.decodeServer(payload)) {
            .pane_opened => |opened| {
                try std.testing.expectEqual(original_pane_id, opened.pane_id);
                try std.testing.expect(!opened.created);
                attached = true;
            },
            .pane_frame => |frame| {
                var spans = frame.spans();
                while (spans.next()) |span| {
                    var frame_cells = span.cells();
                    var index: usize = span.start;
                    while (frame_cells.next()) |cell| : (index += 1) cells[index] = cell;
                }
                saw_output = rowContains(cells[0..40], "TELAR_PERSISTED");
                try second.send(io, try schema.encodeFrameAck(&send_buffer, .{
                    .pane_id = original_pane_id,
                    .frame_id = frame.frame_id,
                }));
            },
            .pane_exited => |exited| {
                try std.testing.expect(attached);
                try std.testing.expect(saw_output);
                try std.testing.expectEqual(@as(u32, 0), exited.value);
                return;
            },
            .request_failed => return error.RuntimeRequestFailed,
            .runtime_stopping => return error.UnexpectedRuntimeShutdown,
            .tab_snapshot => return error.UnexpectedTabSnapshot,
            .history_results => return error.UnexpectedHistoryResults,
            else => return error.UnexpectedTabMessage,
        }
    }
    return error.RuntimeDidNotExit;
}

test "runtime keeps independent panes for different workspaces" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/workspaces.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntil, .{ io, gpa, path, &stop });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    const arguments = [_][]const u8{ "/bin/sleep", "600" };
    var send_buffer: [512]u8 = undefined;
    var receive_buffer: [4096]u8 = undefined;

    var first = try connectRuntimeForTest(io, path);
    try first.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));
    const first_opened = while (true) {
        switch (try schema.decodeServer(try first.receive(io, &receive_buffer))) {
            .pane_opened => |opened| break opened,
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    };
    first.deinit(io);

    try io.sleep(.fromMilliseconds(200), .awake);
    var second = try connectRuntimeForTest(io, path);
    try second.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = "/", .arguments = &arguments },
    }));
    const second_opened = while (true) {
        switch (try schema.decodeServer(try second.receive(io, &receive_buffer))) {
            .pane_opened => |opened| break opened,
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    };
    try std.testing.expect(first_opened.pane_id != second_opened.pane_id);
    try std.testing.expect(!std.meta.eql(first_opened.location, second_opened.location));
    second.deinit(io);

    try io.sleep(.fromMilliseconds(200), .awake);
    var third = try connectRuntimeForTest(io, path);
    defer third.deinit(io);
    try third.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(3),
        .target = .{ .pane = first_opened.pane_id },
        .size = .{ .cols = 40, .rows = 8 },
        .launch = null,
    }));
    const reattached = while (true) {
        switch (try schema.decodeServer(try third.receive(io, &receive_buffer))) {
            .pane_opened => |opened| break opened,
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    };
    try std.testing.expectEqual(first_opened.pane_id, reattached.pane_id);
    try std.testing.expect(std.meta.eql(first_opened.location, reattached.location));
    try std.testing.expect(!reattached.created);
}

test "runtime owns the complete tab lifecycle" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/tabs.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntil, .{ io, gpa, path, &stop });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);
    var send_buffer: [4096]u8 = undefined;
    var receive_buffer: [4096]u8 = undefined;
    const arguments = [_][]const u8{ "/bin/sleep", "600" };
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    var primary: schema.TabLocation = undefined;
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .pane_opened => |opened| {
            primary = opened.location;
            break;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try connection.send(io, try schema.encodeCreateTab(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .workspace = primary.workspace,
        .label = "logs",
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));
    var logs: schema.TabLocation = undefined;
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .tab_created => |created| {
            try std.testing.expectEqualStrings("logs", created.label);
            try std.testing.expectEqual(@as(u16, 1), created.position);
            logs = created.location;
            break;
        },
        .pane_frame => |frame| try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        })),
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try connection.send(io, try schema.encodeRenameTab(&send_buffer, .{
        .request_id = @enumFromInt(3),
        .location = logs,
        .label = "server",
    }));
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .tab_renamed => |renamed| {
            try std.testing.expectEqualStrings("server", renamed.label);
            break;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try connection.send(io, try schema.encodeMoveTab(&send_buffer, .{
        .request_id = @enumFromInt(4),
        .location = logs,
        .direction = .previous,
    }));
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .tab_moved => |moved| {
            try std.testing.expectEqual(@as(u16, 0), moved.position);
            break;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try connection.send(io, try schema.encodeRequestWorkspaceSnapshot(&send_buffer, .{
        .request_id = @enumFromInt(5),
        .workspace = primary.workspace,
    }));
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .workspace_snapshot => |snapshot| {
            try std.testing.expectEqual(@as(u16, 2), snapshot.tab_count);
            var iterator = snapshot.tabs();
            const first = iterator.next().?;
            const second = iterator.next().?;
            try std.testing.expectEqual(logs.tab_id, first.tab_id);
            try std.testing.expectEqualStrings("server", first.label);
            try std.testing.expectEqual(primary.tab_id, second.tab_id);
            try std.testing.expectEqual(@as(u16, 1), first.pane_count);
            break;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try connection.send(io, try schema.encodeCloseTab(&send_buffer, .{
        .request_id = @enumFromInt(6),
        .location = logs,
    }));
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .tab_closed => |closed| {
            try std.testing.expect(!closed.workspace_closed);
            break;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try connection.send(io, try schema.encodeCloseTab(&send_buffer, .{
        .request_id = @enumFromInt(7),
        .location = primary,
    }));
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .tab_closed => |closed| {
            try std.testing.expect(closed.workspace_closed);
            break;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
}

test "a reconnect restores tab order labels and pane membership" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/tab-reconnect.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntil, .{ io, gpa, path, &stop });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var send_buffer: [4096]u8 = undefined;
    var receive_buffer: [4096]u8 = undefined;
    const arguments = [_][]const u8{ "/bin/sleep", "600" };
    var first = try connectRuntimeForTest(io, path);
    try first.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));
    const primary = while (true) switch (try schema.decodeServer(try first.receive(io, &receive_buffer))) {
        .pane_opened => |opened| break opened.location,
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try first.send(io, try schema.encodeCreateTab(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .workspace = primary.workspace,
        .label = "agents",
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));
    const agents = while (true) switch (try schema.decodeServer(try first.receive(io, &receive_buffer))) {
        .tab_created => |created| break created.location,
        .pane_frame => |frame| try first.send(io, try schema.encodeFrameAck(&send_buffer, .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        })),
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
    try first.send(io, try schema.encodeMoveTab(&send_buffer, .{
        .request_id = @enumFromInt(3),
        .location = agents,
        .direction = .previous,
    }));
    while (true) switch (try schema.decodeServer(try first.receive(io, &receive_buffer))) {
        .tab_moved => break,
        .pane_frame => |frame| try first.send(io, try schema.encodeFrameAck(&send_buffer, .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        })),
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
    first.deinit(io);

    try io.sleep(.fromMilliseconds(200), .awake);
    var second = try connectRuntimeForTest(io, path);
    defer second.deinit(io);
    try second.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(4),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));
    while (true) switch (try schema.decodeServer(try second.receive(io, &receive_buffer))) {
        .pane_opened => |opened| {
            try std.testing.expect(!opened.created);
            try std.testing.expectEqual(agents.tab_id, opened.location.tab_id);
            break;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try second.send(io, try schema.encodeRequestWorkspaceSnapshot(&send_buffer, .{
        .request_id = @enumFromInt(5),
        .workspace = primary.workspace,
    }));
    while (true) switch (try schema.decodeServer(try second.receive(io, &receive_buffer))) {
        .workspace_snapshot => |snapshot| {
            try std.testing.expectEqual(@as(u16, 2), snapshot.tab_count);
            var iterator = snapshot.tabs();
            const first_tab = iterator.next().?;
            const second_tab = iterator.next().?;
            try std.testing.expectEqual(agents.tab_id, first_tab.tab_id);
            try std.testing.expectEqualStrings("agents", first_tab.label);
            try std.testing.expectEqual(primary.tab_id, second_tab.tab_id);
            try std.testing.expectEqualStrings("main", second_tab.label);
            try std.testing.expectEqual(@as(u16, 1), first_tab.pane_count);
            try std.testing.expectEqual(@as(u16, 1), second_tab.pane_count);
            break;
        },
        .pane_frame => |frame| try second.send(io, try schema.encodeFrameAck(&send_buffer, .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        })),
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try second.send(io, try schema.encodeRequestTabSnapshot(&send_buffer, .{
        .request_id = @enumFromInt(6),
        .location = primary,
    }));
    while (true) switch (try schema.decodeServer(try second.receive(io, &receive_buffer))) {
        .tab_snapshot => |snapshot| {
            try std.testing.expectEqual(primary.tab_id, snapshot.location.tab_id);
            try std.testing.expectEqual(@as(u16, 1), snapshot.pane_count);
            break;
        },
        .pane_frame => |frame| try second.send(io, try schema.encodeFrameAck(&send_buffer, .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        })),
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
}

test "an identical pane resize does not emit another snapshot" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/same-resize.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntil, .{ io, gpa, path, &stop });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);
    var send_buffer: [512]u8 = undefined;
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{ "/bin/sleep", "600" } },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    var pane_id: schema.PaneId = .invalid;
    var location: ?schema.TabLocation = null;
    var acknowledged_snapshot = false;
    while (!acknowledged_snapshot) {
        switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
            .pane_opened => |opened| {
                pane_id = opened.pane_id;
                location = opened.location;
            },
            .pane_frame => |frame| {
                try std.testing.expectEqual(@as(u64, 0), frame.base_frame_id);
                try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
                    .pane_id = frame.pane_id,
                    .frame_id = frame.frame_id,
                }));
                acknowledged_snapshot = true;
            },
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }
    try std.testing.expect(pane_id != .invalid);
    try connection.send(io, try schema.encodePaneResize(&send_buffer, .{
        .pane_id = pane_id,
        .size = .{ .cols = 40, .rows = 8 },
    }));
    try connection.send(io, try schema.encodeRequestTabSnapshot(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .location = location.?,
    }));
    while (true) {
        switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
            .tab_snapshot => |snapshot| {
                try std.testing.expectEqual(
                    @as(schema.RequestId, @enumFromInt(2)),
                    snapshot.request_id,
                );
                return;
            },
            .pane_frame => return error.RedundantFrameAfterIdenticalResize,
            .request_failed => return error.RuntimeRequestFailed,
            else => return error.UnexpectedRuntimeMessage,
        }
    }
}

test "runtime persists terminal-edited commands without shell integration" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema.v2;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var socket_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(
        &socket_buffer,
        "{s}/history.sock",
        .{directory},
    );
    var database_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const database_path = try std.fmt.bufPrintZ(
        &database_buffer,
        "{s}/history.db",
        .{directory},
    );

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serveUntilWithHistory, .{
        io,
        gpa,
        socket_path,
        database_path,
        &stop,
    });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, socket_path);
    defer connection.deinit(io);
    var send_buffer: [2048]u8 = undefined;
    const arguments = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf '$ '; IFS= read -r line; sleep 0.01; exit 7",
    };
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    var pane_id: schema.PaneId = .invalid;
    var input_sent = false;
    var cells: [80 * 24]core.ui.Cell = @splat(.{});
    while (true) {
        switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
            .pane_opened => |opened| pane_id = opened.pane_id,
            .pane_frame => |frame| {
                applyFrameCells(&cells, frame);
                try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
                    .pane_id = frame.pane_id,
                    .frame_id = frame.frame_id,
                }));
                if (!input_sent and rowContains(&cells, "$ ")) {
                    try connection.send(io, try schema.encodePaneInput(&send_buffer, .{
                        .pane_id = frame.pane_id,
                        .bytes = "echo persisX\x7fted\n",
                    }));
                    input_sent = true;
                }
            },
            .pane_exited => {
                try std.testing.expect(input_sent);
                break;
            },
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }
    try std.testing.expect(pane_id != .invalid);

    var history_connection = try connectRuntimeForTest(io, socket_path);
    defer history_connection.deinit(io);
    try history_connection.send(io, try schema.encodeQueryHistory(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .query = "persisted",
        .scope = .pane,
        .pane_id = pane_id,
        .limit = 10,
    }));
    while (true) {
        switch (try schema.decodeServer(try history_connection.receive(io, receive_buffer))) {
            .history_results => |results| {
                try std.testing.expectEqual(@as(u16, 1), results.entry_count);
                var entries = results.entries();
                const entry = entries.next() orelse return error.MissingHistoryEntry;
                try std.testing.expectEqualStrings("echo persisted", entry.command);
                try std.testing.expectEqual(@as(?i32, 7), entry.exit_code);
                try std.testing.expectEqual(schema.HistoryStatus.completed, entry.status);
                return;
            },
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }
}

fn connectRuntimeForTest(io: std.Io, path: []const u8) !core.transport.SocketChannel {
    for (0..200) |_| {
        var connection = frontend.transport.local.connect(io, path) catch {
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        const negotiated = frontend.transport.handshake.perform(io, &connection) catch {
            connection.deinit(io);
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        if (negotiated == .accepted) return connection;
        connection.deinit(io);
        return error.IncompatibleRuntime;
    }
    return error.RuntimeDidNotStart;
}

fn rowContains(cells: []const core.ui.Cell, needle: []const u8) bool {
    if (needle.len > cells.len) return false;
    var start: usize = 0;
    while (start + needle.len <= cells.len) : (start += 1) {
        for (needle, 0..) |byte, offset| {
            const cell = &cells[start + offset];
            if (cell.len != 1 or cell.bytes[0] != byte) break;
        } else return true;
    }
    return false;
}

fn applyFrameCells(cells: []core.ui.Cell, frame: core.schema.v2.frame.FrameView) void {
    var spans = frame.spans();
    while (spans.next()) |span| {
        var source = span.cells();
        var index: usize = span.start;
        while (source.next()) |cell| : (index += 1) cells[index] = cell;
    }
}
