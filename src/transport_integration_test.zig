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
        .request_id = 1,
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

test "runtime owns the PTY and streams pane frames to the client" {
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
        .request_id = 1,
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    var cells: [40 * 8]core.ui.Cell = @splat(.{});
    var pane_id: u64 = 0;
    var saw_output = false;

    for (0..64) |_| {
        const payload = try connection.receive(io, receive_buffer);
        switch (try schema.decodeServer(payload)) {
            .pane_opened => |opened| {
                pane_id = opened.pane_id;
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
                return;
            },
            .request_failed => |failure| {
                std.debug.print("runtime integration failure: {s}\n", .{failure.message});
                return error.RuntimeRequestFailed;
            },
            .runtime_stopping => return error.UnexpectedRuntimeShutdown,
        }
    }
    return error.RuntimeDidNotExit;
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
        .request_id = 1,
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    var original_pane_id: u64 = 0;
    while (original_pane_id == 0) {
        switch (try schema.decodeServer(try first.receive(io, receive_buffer))) {
            .pane_opened => |opened| original_pane_id = opened.pane_id,
            .request_failed => return error.RuntimeRequestFailed,
            .runtime_stopping => return error.UnexpectedRuntimeShutdown,
            else => {},
        }
    }
    first.deinit(io);

    try io.sleep(.fromMilliseconds(200), .awake);
    var second = try connectRuntimeForTest(io, path);
    defer second.deinit(io);
    try second.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = 2,
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
        }
    }
    return error.RuntimeDidNotExit;
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
