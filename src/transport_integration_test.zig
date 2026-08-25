const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const handshake = core.handshake;

const test_receive_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(5) },
};

const TestReceiveEvent = union(enum) {
    received: anyerror![]u8,
    expired: anyerror!void,
};

/// Runtime integration reads must fail instead of hanging the whole test
/// process. A timeout makes the framed stream unusable because the reader may
/// have consumed part of a frame, so the failure path shuts the channel down.
const RuntimeTestChannel = struct {
    channel: core.transport.SocketChannel,

    fn send(self: *RuntimeTestChannel, io: std.Io, payload: []const u8) !void {
        return self.channel.send(io, payload);
    }

    fn receive(self: *RuntimeTestChannel, io: std.Io, buffer: []u8) ![]u8 {
        var storage: [2]TestReceiveEvent = undefined;
        var select = std.Io.Select(TestReceiveEvent).init(io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.received, receiveRuntimeFrame, .{ io, &self.channel, buffer });
        try select.concurrent(.expired, waitForTestReceiveDeadline, .{io});
        return switch (try select.await()) {
            .received => |result| try result,
            .expired => |result| {
                try result;
                self.channel.shutdown(io);
                return error.TestReceiveDeadlineExceeded;
            },
        };
    }

    fn deinit(self: *RuntimeTestChannel, io: std.Io) void {
        self.channel.deinit(io);
    }
};

fn receiveRuntimeFrame(
    io: std.Io,
    connection: *core.transport.SocketChannel,
    buffer: []u8,
) anyerror![]u8 {
    return connection.receive(io, buffer);
}

fn waitForTestReceiveDeadline(io: std.Io) anyerror!void {
    return test_receive_timeout.sleep(io);
}

const HandshakeWorker = struct {
    io: std.Io,
    connection: *core.transport.SocketChannel,
    supported: handshake.SchemaId,
    response: ?handshake.ServerResponse = null,
    failure: ?anyerror = null,

    fn run(worker: *@This()) void {
        worker.response = backend.transport.handshake.performSchema(
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

test "frontend and backend accept the same schema" {
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
        .supported = handshake.schema_id,
    };
    const thread = try std.Thread.spawn(.{}, HandshakeWorker.run, .{&worker});
    const client_response = try frontend.transport.handshake.performSchema(
        io,
        &client,
        handshake.schema_id,
    );
    thread.join();

    if (worker.failure) |err| return err;
    try std.testing.expectEqual(handshake.schema_id, client_response.accepted.schema);
    try std.testing.expectEqualDeep(client_response, worker.response.?);
}

test "backend explains an incompatible schema" {
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

    var client_schema = handshake.schema_id;
    client_schema[0] ^= 1;
    var worker = HandshakeWorker{
        .io = io,
        .connection = &peer,
        .supported = handshake.schema_id,
    };
    const thread = try std.Thread.spawn(.{}, HandshakeWorker.run, .{&worker});
    const client_response = try frontend.transport.handshake.performSchema(
        io,
        &client,
        client_schema,
    );
    thread.join();

    if (worker.failure) |err| return err;
    try std.testing.expectEqual(
        handshake.RejectReason.incompatible_schema,
        client_response.rejected.reason,
    );
    try std.testing.expectEqual(handshake.schema_id, client_response.rejected.expected_schema);
    try std.testing.expectEqualDeep(client_response, worker.response.?);
}

test "runtime stops with a live pane and removes its endpoint" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
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
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
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

test "partial pane actor startup aborts only that launch" {
    for ([_]backend.history.LaunchPhase{
        .pane_registration,
        .wait_actor,
        .output_actor,
    }) |phase| try expectPartialLaunchRecovery(phase);
}

fn expectPartialLaunchRecovery(phase: backend.history.LaunchPhase) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/launch-fault.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var fault: backend.runtime.LaunchTestFault = .{ .phase = phase };
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
        .launch_fault = &fault,
    } });
    var server_finished = false;
    defer if (!server_finished) {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    };

    var connection = try connectRuntimeForTest(io, path);
    var connection_open = true;
    defer if (connection_open) connection.deinit(io);
    var send_buffer: [1024]u8 = undefined;
    const arguments = [_][]const u8{ "/bin/sleep", "600" };
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    var receive_buffer: [4096]u8 = undefined;
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .request_failed => |failed| {
            try std.testing.expectEqual(schema.FailureCode.spawn_failed, failed.code);
            break;
        },
        .pane_opened => return error.AbortedPaneBecameVisible,
        .runtime_stopping => return error.UnexpectedRuntimeShutdown,
        else => {},
    };
    try std.testing.expect(fault.claimed.load(.acquire));

    // The failed default launch removed both its provisional workspace and
    // geometry lease. A second request for the same cwd can commit normally.
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));
    var pane_id: schema.PaneId = .invalid;
    while (pane_id == .invalid) switch (try schema.decodeServer(
        try connection.receive(io, &receive_buffer),
    )) {
        .pane_opened => |opened| {
            try std.testing.expect(opened.created);
            try std.testing.expectEqual(@as(u64, 2), schema.id.raw(opened.pane_id));
            pane_id = opened.pane_id;
        },
        .request_failed => return error.SecondPaneLaunchFailed,
        .runtime_stopping => return error.UnexpectedRuntimeShutdown,
        else => {},
    };

    connection.deinit(io);
    connection_open = false;
    var reconnected = try connectRuntimeForTest(io, path);
    defer reconnected.deinit(io);
    try reconnected.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(3),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));
    while (true) switch (try schema.decodeServer(try reconnected.receive(io, &receive_buffer))) {
        .pane_opened => |opened| {
            try std.testing.expect(!opened.created);
            try std.testing.expectEqual(pane_id, opened.pane_id);
            break;
        },
        .request_failed => return error.ReconnectCreatedDuplicatePane,
        .runtime_stopping => return error.UnexpectedRuntimeShutdown,
        else => {},
    };

    stop.putOneUncancelable(io, 0) catch unreachable;
    try server.await(io);
    server_finished = true;
}

test "runtime destroys a pane after its shell exits" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/runtime.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);

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
    var saw_tab_closed = false;
    var rejected_reattach = false;
    var rejected_snapshot = false;

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
                while (try spans.next()) |span| {
                    var frame_cells = span.cells();
                    var index: usize = span.start;
                    while (try frame_cells.next()) |cell| : (index += 1) cells[index] = cell;
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
                switch (@intFromEnum(failure.request_id)) {
                    2 => {
                        try std.testing.expectEqual(schema.FailureCode.pane_not_found, failure.code);
                        rejected_reattach = true;
                    },
                    3 => {
                        try std.testing.expectEqual(schema.FailureCode.tab_not_found, failure.code);
                        rejected_snapshot = true;
                    },
                    else => {
                        std.debug.print("runtime integration failure: {s}\n", .{failure.message});
                        return error.RuntimeRequestFailed;
                    },
                }
            },
            .runtime_stopping => return error.UnexpectedRuntimeShutdown,
            .tab_closed => |closed| {
                try std.testing.expect(saw_exit);
                try std.testing.expectEqual(schema.RequestId.none, closed.request_id);
                try std.testing.expectEqualDeep(location.?, closed.location);
                try std.testing.expect(closed.workspace_closed);
                saw_tab_closed = true;
            },
            .history_results => return error.UnexpectedHistoryResults,
            else => return error.UnexpectedTabMessage,
        }
        if (saw_exit and saw_tab_closed and rejected_reattach and rejected_snapshot) return;
    }
    return error.RuntimeDidNotExit;
}

test "the last pane closes only its tab when the workspace has another tab" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/tab-exit.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);
    var send_buffer: [4096]u8 = undefined;
    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);

    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{ "/bin/sleep", "600" } },
    }));
    const primary = while (true) switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
        .pane_opened => |opened| break opened.location,
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try connection.send(io, try schema.encodeCreateTab(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .workspace = primary.workspace,
        .label = "ephemeral",
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{"/usr/bin/true"} },
    }));

    var ephemeral: ?schema.TabLocation = null;
    var ephemeral_pane: schema.PaneId = .invalid;
    var saw_exit = false;
    var saw_close = false;
    while (!saw_close) switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
        .tab_created => |created| {
            ephemeral = created.location;
            ephemeral_pane = created.root_pane_id;
        },
        .pane_frame => |frame| try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        })),
        .pane_exited => |exited| {
            if (exited.pane_id != ephemeral_pane) continue;
            try std.testing.expect(ephemeral != null);
            saw_exit = true;
        },
        .tab_closed => |closed| {
            try std.testing.expect(saw_exit);
            try std.testing.expectEqual(schema.RequestId.none, closed.request_id);
            try std.testing.expectEqualDeep(ephemeral.?, closed.location);
            try std.testing.expect(!closed.workspace_closed);
            saw_close = true;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    try connection.send(io, try schema.encodeRequestWorkspaceSnapshot(&send_buffer, .{
        .request_id = @enumFromInt(3),
        .workspace = primary.workspace,
    }));
    while (true) switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
        .workspace_snapshot => |snapshot| {
            try std.testing.expectEqual(@as(u16, 1), snapshot.tab_count);
            var tabs = snapshot.tabs();
            try std.testing.expectEqual(primary.tab_id, ((try tabs.next()).?).tab_id);
            break;
        },
        .pane_frame => |frame| try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        })),
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
}

test "an exited detached pane removes its tab and workspace" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/detached-exit.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var send_buffer: [1024]u8 = undefined;
    var receive_buffer: [4096]u8 = undefined;
    var first = try connectRuntimeForTest(io, path);
    try first.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{
            .cwd = directory,
            .arguments = &.{ "/bin/sh", "-c", "sleep 0.05" },
        },
    }));
    const old_location = while (true) switch (try schema.decodeServer(try first.receive(io, &receive_buffer))) {
        .pane_opened => |opened| break opened.location,
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
    first.deinit(io);

    try io.sleep(.fromMilliseconds(200), .awake);
    var second = try connectRuntimeForTest(io, path);
    defer second.deinit(io);
    try second.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{ "/bin/sleep", "600" } },
    }));
    while (true) switch (try schema.decodeServer(try second.receive(io, &receive_buffer))) {
        .pane_opened => |opened| {
            try std.testing.expect(!std.meta.eql(old_location, opened.location));
            break;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
}

test "one client drives two attached panes and closes either one" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/multi-pane.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
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
                try applyFrameCells(cells, frame);
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
                try std.testing.expectEqual(first_id, ((try panes.next()).?).pane_id);
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
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/persistent.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
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
                while (try spans.next()) |span| {
                    var frame_cells = span.cells();
                    var index: usize = span.start;
                    while (try frame_cells.next()) |cell| : (index += 1) cells[index] = cell;
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
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/workspaces.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
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
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/tabs.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
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
            const first = (try iterator.next()).?;
            const second = (try iterator.next()).?;
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
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/tab-reconnect.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
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
            const first_tab = (try iterator.next()).?;
            const second_tab = (try iterator.next()).?;
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
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/same-resize.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
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
    const schema = core.schema;
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
    var server = try io.concurrent(backend.runtime.serve, .{
        io,
        gpa,
        socket_path,
        .{
            .environment = std.testing.environ,
            .history_path = database_path,
            .stop = &stop,
        },
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
        "cd /; printf '\\033_Ga=T,f=32,s=1,v=1,t=d,i=19,q=2,C=1;AQID/w==\\033\\\\'; " ++
            "printf '$ '; IFS= read -r line; sleep 1; exit 7",
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
    var saw_graphics = false;
    var cells: [80 * 24]core.ui.Cell = @splat(.{});
    while (true) {
        switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
            .pane_opened => |opened| pane_id = opened.pane_id,
            .pane_frame => |frame| {
                try applyFrameCells(&cells, frame);
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
            .graphics_image => |image| {
                try std.testing.expectEqual(@as(u32, 19), image.image.key.image_id);
                saw_graphics = true;
            },
            .pane_exited => {
                try std.testing.expect(input_sent);
                try std.testing.expect(saw_graphics);
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
                const entry = (try entries.next()) orelse return error.MissingHistoryEntry;
                try std.testing.expectEqualStrings("echo persisted", entry.command);
                // The cwd is sampled by the observation worker at submit
                // time, not by the per-keystroke input handler.
                try std.testing.expectEqualStrings("/", entry.cwd);
                try std.testing.expect(std.mem.indexOf(u8, entry.command, "\x1b_G") == null);
                try std.testing.expectEqual(@as(?i32, 7), entry.exit_code);
                try std.testing.expectEqual(schema.HistoryStatus.completed, entry.status);
                return;
            },
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }
}

test "PTY input remains live while the bounded ingest actor is occupied" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var socket_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "{s}/ingest.sock", .{directory});
    var sentinel_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sentinel_path = try std.fmt.bufPrint(&sentinel_buffer, "{s}/input-forwarded", .{directory});

    var stop_storage: [1]u8 = undefined;
    var entered_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var entered: std.Io.Queue(u8) = .init(&entered_storage);
    var release: std.Io.Queue(u8) = .init(&release_storage);
    var gate: backend.runtime.IngestTestGate = .{
        .entered = &entered,
        .release = &release,
    };
    var server = try io.concurrent(backend.runtime.serve, .{
        io,
        gpa,
        socket_path,
        .{
            .environment = std.testing.environ,
            .stop = &stop,
            .ingest_gate = &gate,
        },
    });
    var gate_released = false;
    defer {
        if (!gate_released) release.putOneUncancelable(io, 0) catch {};
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, socket_path);
    defer connection.deinit(io);
    var command_buffer: [2 * std.fs.max_path_bytes]u8 = undefined;
    const command = try std.fmt.bufPrint(
        &command_buffer,
        "stty raw -echo; printf 'MEDIA_READY\\n'; " ++
            "dd bs=1 count=1 of=/dev/null 2>/dev/null; " ++
            ": > '{s}'; printf 'INPUT_FORWARDED\\n'; sleep 1",
        .{sentinel_path},
    );
    const arguments = [_][]const u8{ "/bin/sh", "-c", command };
    var send_buffer: [4096]u8 = undefined;
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    var pane_id: schema.PaneId = .invalid;
    while (pane_id == .invalid) switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
        .pane_opened => |opened| pane_id = opened.pane_id,
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    // The first PTY burst is deliberately held inside the interactive VT
    // actor. The runtime event loop and PTY input writer must remain
    // independent of that actor.
    _ = try entered.getOne(io);
    const started = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    try connection.send(io, try schema.encodePaneInput(&send_buffer, .{
        .pane_id = pane_id,
        .bytes = "x",
    }));

    var forwarded = false;
    for (0..1000) |_| {
        if (std.Io.Dir.cwd().statFile(io, sentinel_path, .{})) |_| {
            forwarded = true;
            break;
        } else |err| switch (err) {
            error.FileNotFound => try io.sleep(.fromMilliseconds(1), .awake),
            else => return err,
        }
    }
    const elapsed: u64 = @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds() - started);
    try std.testing.expect(forwarded);
    try std.testing.expect(elapsed < std.time.ns_per_s);

    release.putOneUncancelable(io, 0) catch unreachable;
    gate_released = true;
}

test "runtime terminates KGP, replies to the child, and resynchronizes graphics" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var socket_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "{s}/graphics.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, socket_path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, socket_path);
    defer connection.deinit(io);
    const script =
        "stty raw -echo; " ++
        "printf '\\033_Ga=T,f=32,o=z,s=1,v=1,t=d,i=7,q=2,C=1,c=2,r=2;eAFjZGL+DwABEwEG\\033\\\\'; " ++
        "printf '\\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\\033\\\\'; " ++
        "reply=$(dd bs=1 count=12 2>/dev/null); " ++
        "case \"$reply\" in *'Gi=31;OK'*) printf 'KGP_CHILD_OK\\n';; *) printf 'KGP_CHILD_BAD\\n';; esac; " ++
        "sleep 2";
    const arguments = [_][]const u8{ "/bin/sh", "-c", script };
    var send_buffer: [2048]u8 = undefined;
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{
            .cols = 40,
            .rows = 8,
            .cell_width_px = 10,
            .cell_height_px = 20,
        },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    var store = frontend.kitty.Store.init(gpa);
    defer store.deinit();
    var cells: [40 * 8]core.ui.Cell = @splat(.{});
    var pane_id: schema.PaneId = .invalid;
    var saw_child_reply = false;
    var saw_image = false;
    var saw_placement = false;
    var requested_resync = false;
    var snapshot_open = false;
    var snapshot_complete = false;

    for (0..256) |_| {
        const payload = try connection.receive(io, receive_buffer);
        switch (try schema.decodeServer(payload)) {
            .pane_opened => |opened| pane_id = opened.pane_id,
            .pane_frame => |frame| {
                try applyFrameCells(&cells, frame);
                saw_child_reply = rowContains(&cells, "KGP_CHILD_OK");
                if (rowContains(&cells, "KGP_CHILD_BAD")) return error.KittyQueryReplyMissing;
                try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
                    .pane_id = frame.pane_id,
                    .frame_id = frame.frame_id,
                }));
            },
            .graphics_snapshot => |snapshot| {
                try store.applySnapshot(snapshot);
                if (requested_resync) switch (snapshot.phase) {
                    .begin => snapshot_open = true,
                    .end => snapshot_complete = snapshot_open,
                };
            },
            .graphics_image => |image| {
                try store.applyImage(image);
                saw_image = true;
            },
            .graphics_image_chunk => |chunk| try store.applyChunk(chunk),
            .graphics_placement => |placement| {
                try store.applyPlacement(placement);
                saw_placement = true;
            },
            .graphics_delete_image => |deleted| try store.deleteImage(deleted),
            .graphics_delete_placement => |deleted| try store.deletePlacement(deleted),
            .pane_exited => return error.GraphicsPaneExitedBeforeResync,
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }

        if (!requested_resync and saw_child_reply and saw_image and saw_placement) {
            try std.testing.expectEqual(@as(usize, 1), store.images.count());
            try std.testing.expectEqual(@as(usize, 1), store.placements.count());
            var images = store.images.iterator();
            const image = images.next().?.value_ptr;
            try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, image.pixels);
            try connection.send(io, try schema.encodeRequestGraphicsSnapshot(&send_buffer, .{
                .pane_id = pane_id,
            }));
            requested_resync = true;
        }
        if (snapshot_complete) {
            try std.testing.expectEqual(@as(usize, 1), store.images.count());
            try std.testing.expectEqual(@as(usize, 1), store.placements.count());
            return;
        }
    }
    return error.GraphicsIntegrationTimedOut;
}

test "a silent connection cannot starve later clients" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/starve.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    // Wait until the runtime listens, then park a connection that never sends
    // its hello. The accept pipeline must not wait on it.
    var probe = try connectRuntimeForTest(io, path);
    probe.deinit(io);
    var silent = while (true) {
        if (frontend.transport.local.connect(io, path)) |connection| {
            break connection;
        } else |_| try io.sleep(.fromMilliseconds(1), .awake);
    };
    defer silent.deinit(io);

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);
    var send_buffer: [512]u8 = undefined;
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{ "/bin/sleep", "600" } },
    }));
    var receive_buffer: [4096]u8 = undefined;
    while (true) switch (try schema.decodeServer(try connection.receive(io, &receive_buffer))) {
        .pane_opened => break,
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
}

test "input to one pane flows while another pane's PTY is wedged" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/wedged.sock", .{directory});
    var sentinel_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sentinel_path = try std.fmt.bufPrint(&sentinel_buffer, "{s}/b-input", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);
    var send_buffer: [core.schema.max_input_bytes + 512]u8 = undefined;
    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);

    // Pane A: raw mode, then stopped. Its PTY input queue fills and the
    // master write blocks, exactly like a child suspended mid-read.
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{
            "/bin/sh", "-c", "stty raw -echo; printf 'A_READY\\n'; kill -STOP $$; sleep 600",
        } },
    }));
    var wedged_pane: schema.PaneId = .invalid;
    var wedged_location: schema.TabLocation = undefined;
    var cells: [40 * 8]core.ui.Cell = @splat(.{});
    var a_ready = false;
    while (!a_ready) switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
        .pane_opened => |opened| {
            wedged_pane = opened.pane_id;
            wedged_location = opened.location;
        },
        .pane_frame => |frame| {
            try applyFrameCells(&cells, frame);
            a_ready = rowContains(&cells, "A_READY");
            try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
                .pane_id = frame.pane_id,
                .frame_id = frame.frame_id,
            }));
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    // Pane B: acknowledges one byte of input through the filesystem.
    var command_buffer: [2 * std.fs.max_path_bytes]u8 = undefined;
    const command = try std.fmt.bufPrint(
        &command_buffer,
        "stty raw -echo; dd bs=1 count=1 of=/dev/null 2>/dev/null; : > '{s}'; sleep 600",
        .{sentinel_path},
    );
    try connection.send(io, try schema.encodeCreatePane(&send_buffer, .{
        .request_id = @enumFromInt(2),
        .location = wedged_location,
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{ "/bin/sh", "-c", command } },
    }));
    var live_pane: schema.PaneId = .invalid;
    while (live_pane == .invalid) switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
        .pane_opened => |opened| if (opened.request_id == @as(schema.RequestId, @enumFromInt(2))) {
            live_pane = opened.pane_id;
        },
        .pane_frame => |frame| try connection.send(io, try schema.encodeFrameAck(&send_buffer, .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        })),
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
    // Give pane B's shell a moment to reach its read.
    try io.sleep(.fromMilliseconds(100), .awake);

    // Flood the wedged pane far past any kernel PTY buffer.
    const flood = [_]u8{'x'} ** (16 * 1024);
    for (0..4) |_| {
        try connection.send(io, try schema.encodePaneInput(&send_buffer, .{
            .pane_id = wedged_pane,
            .bytes = &flood,
        }));
    }
    try connection.send(io, try schema.encodePaneInput(&send_buffer, .{
        .pane_id = live_pane,
        .bytes = "y",
    }));

    var forwarded = false;
    for (0..3000) |_| {
        if (std.Io.Dir.cwd().statFile(io, sentinel_path, .{})) |_| {
            forwarded = true;
            break;
        } else |err| switch (err) {
            error.FileNotFound => try io.sleep(.fromMilliseconds(1), .awake),
            else => return err,
        }
    }
    try std.testing.expect(forwarded);
}

test "two clients observe one pane with independent frame acknowledgement" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/multi-client.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var first = try connectRuntimeForTest(io, path);
    var first_open = true;
    defer if (first_open) first.deinit(io);
    var first_send: [2048]u8 = undefined;
    const arguments = [_][]const u8{
        "/bin/sh",
        "-c",
        "stty raw -echo; while IFS= read -r line; do printf '%s\\r\\n' \"$line\"; done",
    };
    try first.send(io, try schema.encodeOpenPane(&first_send, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const first_receive = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(first_receive);
    var first_cells: [40 * 8]core.ui.Cell = @splat(.{});
    var pane_id: schema.PaneId = .invalid;
    var first_snapshot = false;
    while (pane_id == .invalid or !first_snapshot) {
        switch (try schema.decodeServer(try first.receive(io, first_receive))) {
            .pane_opened => |opened| pane_id = opened.pane_id,
            .pane_frame => |frame| {
                try applyFrameCells(&first_cells, frame);
                first_snapshot = frame.base_frame_id == 0;
                try first.send(io, try schema.encodeFrameAck(&first_send, .{
                    .pane_id = frame.pane_id,
                    .frame_id = frame.frame_id,
                }));
            },
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }

    var second = try connectRuntimeForTest(io, path);
    defer second.deinit(io);
    var second_send: [2048]u8 = undefined;
    try second.send(io, try schema.encodeOpenPane(&second_send, .{
        .request_id = @enumFromInt(1),
        .target = .{ .pane = pane_id },
        .size = .{ .cols = 80, .rows = 20 },
        .launch = null,
    }));
    const second_receive = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(second_receive);
    var second_cells: [40 * 8]core.ui.Cell = @splat(.{});
    var second_opened = false;
    var second_snapshot = false;
    while (!second_opened or !second_snapshot) {
        switch (try schema.decodeServer(try second.receive(io, second_receive))) {
            .pane_opened => |opened| {
                try std.testing.expectEqual(pane_id, opened.pane_id);
                second_opened = true;
            },
            .pane_frame => |frame| {
                // The second client is not the workspace geometry owner, so
                // its requested 80x20 cannot resize the shared PTY.
                try std.testing.expectEqual(@as(u16, 40), frame.cols);
                try std.testing.expectEqual(@as(u16, 8), frame.rows);
                try applyFrameCells(&second_cells, frame);
                second_snapshot = frame.base_frame_id == 0;
                try second.send(io, try schema.encodeFrameAck(&second_send, .{
                    .pane_id = frame.pane_id,
                    .frame_id = frame.frame_id,
                }));
            },
            .request_failed => return error.RuntimeRequestFailed,
            else => {},
        }
    }

    try first.send(io, try schema.encodePaneInput(&first_send, .{
        .pane_id = pane_id,
        .bytes = "BOTH_CLIENTS\n",
    }));
    var first_saw_shared = false;
    while (!first_saw_shared) switch (try schema.decodeServer(try first.receive(io, first_receive))) {
        .pane_frame => |frame| {
            try applyFrameCells(&first_cells, frame);
            first_saw_shared = rowContains(&first_cells, "BOTH_CLIENTS");
            try first.send(io, try schema.encodeFrameAck(&first_send, .{
                .pane_id = frame.pane_id,
                .frame_id = frame.frame_id,
            }));
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
    var second_saw_shared = false;
    while (!second_saw_shared) switch (try schema.decodeServer(try second.receive(io, second_receive))) {
        .pane_frame => |frame| {
            try applyFrameCells(&second_cells, frame);
            second_saw_shared = rowContains(&second_cells, "BOTH_CLIENTS");
            try second.send(io, try schema.encodeFrameAck(&second_send, .{
                .pane_id = frame.pane_id,
                .frame_id = frame.frame_id,
            }));
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    first.deinit(io);
    first_open = false;
    try second.send(io, try schema.encodePaneInput(&second_send, .{
        .pane_id = pane_id,
        .bytes = "SECOND_SURVIVES\n",
    }));
    var second_saw_survives = false;
    var lease_released = false;
    while (!second_saw_survives or !lease_released) switch (try schema.decodeServer(try second.receive(io, second_receive))) {
        .pane_frame => |frame| {
            try applyFrameCells(&second_cells, frame);
            try second.send(io, try schema.encodeFrameAck(&second_send, .{
                .pane_id = frame.pane_id,
                .frame_id = frame.frame_id,
            }));
            if (rowContains(&second_cells, "SECOND_SURVIVES")) second_saw_survives = true;
        },
        // The owner's disconnect frees the geometry lease and the runtime
        // resyncs the survivor so it can re-offer its own size.
        .resync_required => lease_released = true,
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };

    // The survivor re-offers its geometry, takes the lease over, and the
    // shared PTY finally adopts its 80x20.
    try second.send(io, try schema.encodePaneResize(&second_send, .{
        .pane_id = pane_id,
        .size = .{ .cols = 80, .rows = 20 },
    }));
    var resized_cells: [80 * 20]core.ui.Cell = @splat(.{});
    while (true) switch (try schema.decodeServer(try second.receive(io, second_receive))) {
        .pane_frame => |frame| {
            try second.send(io, try schema.encodeFrameAck(&second_send, .{
                .pane_id = frame.pane_id,
                .frame_id = frame.frame_id,
            }));
            if (frame.cols != 80 or frame.rows != 20) continue;
            try applyFrameCells(&resized_cells, frame);
            return;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
}

test "a stale attachment command does not disconnect the client" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema = core.schema;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/stale-command.sock", .{directory});

    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(backend.runtime.serve, .{ io, gpa, path, .{
        .environment = std.testing.environ,
        .stop = &stop,
    } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }

    var connection = try connectRuntimeForTest(io, path);
    defer connection.deinit(io);
    var send_buffer: [2048]u8 = undefined;
    try connection.send(io, try schema.encodeDetachPane(&send_buffer, .{
        .pane_id = @enumFromInt(999),
    }));

    const arguments = [_][]const u8{ "/bin/sh", "-c", "sleep 1" };
    const request_id: schema.RequestId = @enumFromInt(1);
    try connection.send(io, try schema.encodeOpenPane(&send_buffer, .{
        .request_id = request_id,
        .size = .{ .cols = 20, .rows = 5 },
        .launch = .{ .cwd = directory, .arguments = &arguments },
    }));

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    for (0..32) |_| switch (try schema.decodeServer(try connection.receive(io, receive_buffer))) {
        .pane_opened => |opened| {
            try std.testing.expectEqual(request_id, opened.request_id);
            return;
        },
        .request_failed => return error.RuntimeRequestFailed,
        else => {},
    };
    return error.PaneOpenTimedOut;
}

fn connectRuntimeForTest(io: std.Io, path: []const u8) !RuntimeTestChannel {
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
        if (negotiated == .accepted) return .{ .channel = connection };
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

fn applyFrameCells(cells: []core.ui.Cell, frame: core.schema.frame.FrameView) !void {
    var spans = frame.spans();
    while (try spans.next()) |span| {
        var source = span.cells();
        var index: usize = span.start;
        while (try source.next()) |cell| : (index += 1) cells[index] = cell;
    }
}
