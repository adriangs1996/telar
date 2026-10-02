//! Test bodies for Client. Private implementations are supplied by the
//! owner's test declarations as concrete compile-time functions.
const data = @import("model");
const localsocket = @import("localsocket");
const std = @import("std");
const pacing = @import("pacing");
const core = @import("telar-core");
const Client = @import("Client.zig");
const Job = @import("Job.zig").Job;
const GraphicsRetention = @import("../graphics/GraphicsRetention.zig");
const Credit = @import("../graphics/Credit.zig");
const actions = @import("../input/actions.zig");
const runtime_io = @import("../connection/runtime_io.zig");
const runtime_link = @import("../connection/runtime_link.zig");
const RuntimeResync = @import("../connection/RuntimeResync.zig").RuntimeResync;
const runtime_messages = @import("../connection/runtime_messages.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const workspace_rename = @import("../workspace/workspace_rename.zig");

/// Layout export decodes to the same active pane and split tree.
/// Example: `try client_tests.layoutRoundTrip(writeCommandLayout);`
pub fn layoutRoundTrip(comptime write_layout: fn (*const data.ClientModel, *core.ClientCommand) anyerror!void) !void {
    var app: Client = undefined;
    app.model = data.ClientModel.init(std.testing.allocator, true);
    defer app.model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };

    try data.workspace_handoff.bootstrap(
        &app.model,
        .{
            .pane_id = @enumFromInt(3),
            .location = location,
            .size = .{
                .cols = 80,
                .rows = 24,
            },
        },
    );
    var reply: core.ClientCommand = .{
        .request_id = @enumFromInt(5),
        .route = .{
            .id = 7,
            .generation = 9,
        },
        .action = .layout_get,
    };

    try write_layout(&app.model, &reply);
    var bytes: [core.ClientCommand.capacity / 2]u8 = undefined;
    const decoded = try core.decodeServer(try std.fmt.hexToBytes(&bytes, reply.text()));
    try std.testing.expectEqualDeep(location, decoded.client_layout_snapshot.active_tab.?);
    var tabs = decoded.client_layout_snapshot.tabs();
    const tab = (try tabs.next()).?;
    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(3)), tab.focused_pane);
    try std.testing.expect(try tabs.next() == null);
}

/// Host resources reject empty and stale commits before calling ports.
/// Example: `try client_tests.rejectStaleHostCommits(deliverHostCommit);`
pub fn rejectStaleHostCommits(comptime deliver: fn (*Client, data.HostCommit) anyerror!void) !void {
    const app = try std.testing.allocator.create(Client);
    defer std.testing.allocator.destroy(app);
    // Only the model is initialized: invalid commits must never reach a host port.
    app.model.initInto(
        std.testing.allocator,
        .{
            .pane_gaps = false,
            .host_size = .{
                .cols = 80,
                .rows = 24,
            },
        },
    );
    defer app.model.deinit();

    var capabilities = app.model.host.host_capabilities;
    capabilities.images = .supported;
    const stale_capabilities = (try data.host_capabilities.reconcile(
        &app.model,
        .{
            .capabilities = capabilities,
            .size = app.model.host.host_size,
        },
    )).?;
    capabilities.pointer_pixels = .supported;
    _ = try data.host_capabilities.reconcile(
        &app.model,
        .{
            .capabilities = capabilities,
            .size = app.model.host.host_size,
        },
    );
    const stale_size = (try data.host_capabilities.reconcile(
        &app.model,
        .{
            .capabilities = app.model.host.host_capabilities,
            .size = .{
                .cols = 100,
                .rows = 30,
            },
        },
    )).?;
    _ = try data.host_capabilities.reconcile(
        &app.model,
        .{
            .capabilities = app.model.host.host_capabilities,
            .size = .{
                .cols = 101,
                .rows = 30,
            },
        },
    );

    try std.testing.expectError(error.EmptyHostCommit, deliver(
        app,
        .{
            .capabilities = null,
            .resize = null,
        },
    ));
    try std.testing.expectError(error.StaleHostCommit, deliver(app, stale_capabilities));
    try std.testing.expectError(error.StaleHostCommit, deliver(app, stale_size));
}

/// Starts the runtime jobs a test client queued, as an adapter would. A
/// rejected start finishes through `failJob`, like any adapter's.
const Driver = struct {
    reject: bool = true,
    reads: usize = 0,
    sends: usize = 0,
    payload: []const u8 = &.{},

    fn drain(self: *Driver, app: *Client) !void {
        while (app.to_workers.pop()) |job| {
            self.start(job) catch |err| try app.failJob(job, err);
        }
    }

    fn start(self: *Driver, job: Job) !void {
        switch (job) {
            .runtime_read => |state| {
                self.reads += 1;
                try std.testing.expect(state.receive_pending);
            },
            .runtime_send => |send| {
                self.sends += 1;
                try std.testing.expect(send.state.send_buffer.len != 0);
                if (!self.reject) {
                    self.payload = send.bytes;
                }
            },
            else => return error.UnexpectedJob,
        }

        if (self.reject) {
            return error.DriverBusy;
        }
    }
};

/// Stands in for a connected socket the capturing driver never touches.
var unused_channel: localsocket.SocketChannel = undefined;

/// A client with only the transport and outbox a transport test touches.
fn transportClient(send_buffer: []u8) !*Client {
    const app = try std.testing.allocator.create(Client);
    errdefer std.testing.allocator.destroy(app);
    app.io = std.testing.io;
    app.to_workers = .{};
    app.to_background = .{};
    app.graphics = no_graphics;
    app.model.to_runtime = try .init(std.testing.allocator);
    app.model.runtime_link = .{ .phase = .connected };
    // Handed a connected socket, so a failure ends it as before.
    app.options.machine = null;
    app.forward = null;
    app.channel_owned = false;
    app.lua_generation = null;
    app.runtime_transport = .{
        .connection = &unused_channel,
        .send_buffer = send_buffer,
        .receive_buffer = &.{},
        .read_buffer = &.{},
    };

    return app;
}

fn destroyTransportClient(app: *Client) void {
    app.model.to_runtime.deinit(std.testing.allocator);
    std.testing.allocator.destroy(app);
}

/// Transport scheduling releases rejected reservations and retries queued frames in order.
/// Example: `try client_tests.retryTransportScheduling(flush);`
pub fn retryTransportScheduling(comptime flush: fn (*Client) anyerror!void) !void {
    var capture: Driver = .{};
    var send_buffer: [64]u8 = undefined;
    const app = try transportClient(&send_buffer);
    defer destroyTransportClient(app);
    const state = &app.runtime_transport;

    try runtime_io.startRuntimeRead(app);
    try std.testing.expectError(error.DriverBusy, capture.drain(app));
    try std.testing.expect(!state.receive_pending);
    capture.reject = false;
    try runtime_io.startRuntimeRead(app);
    try capture.drain(app);
    try runtime_io.startRuntimeRead(app);
    try capture.drain(app);
    try std.testing.expectEqual(@as(usize, 2), capture.reads);
    try std.testing.expectError(error.ReadFailed, state.completeRead(error.ReadFailed));
    try std.testing.expect(!state.receive_pending);
    try runtime_io.startRuntimeRead(app);
    try capture.drain(app);
    try std.testing.expectEqual(@as(usize, 3), capture.reads);
    state.cancelRead();

    try flush(app);
    try capture.drain(app);
    try std.testing.expectEqual(@as(usize, 0), capture.sends);
    try app.model.to_runtime.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(1),
            },
        },
    );
    try app.model.to_runtime.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(2),
            },
        },
    );
    capture.reject = true;
    try flush(app);
    try std.testing.expectError(error.DriverBusy, capture.drain(app));
    try std.testing.expect(!app.model.to_runtime.inFlight());
    try std.testing.expectEqual(@as(u8, 2), app.model.to_runtime.len);
    const first = send_buffer;
    capture.reject = false;
    try flush(app);
    try capture.drain(app);
    const first_len = capture.payload.len;
    try std.testing.expectEqualSlices(
        u8,
        first[0..first_len],
        capture.payload,
    );
    try flush(app);
    try capture.drain(app);
    try std.testing.expectEqual(@as(usize, 2), capture.sends);
    try app.model.to_runtime.finishSend({});
    try flush(app);
    try capture.drain(app);
    try std.testing.expectEqual(@as(usize, 3), capture.sends);
    try std.testing.expect(!std.mem.eql(
        u8,
        first[0..first_len],
        capture.payload,
    ));
    try app.model.to_runtime.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), app.model.to_runtime.len);
}

/// Enqueue retains copied input after rejected scheduling and preserves order on retry.
/// Example: `try client_tests.retainQueuedInput(flush);`
pub fn retainQueuedInput(comptime flush: fn (*Client) anyerror!void) !void {
    var capture: Driver = .{};
    var send_buffer: [data.input_limits.max_encoded_bytes + 64]u8 = undefined;
    const app = try transportClient(&send_buffer);
    defer destroyTransportClient(app);

    const pane: core.PaneId = @enumFromInt(1);
    var source = [_]u8{
        'x',
    } ** (data.input_limits.max_encoded_bytes + 1);

    try runtime_io.sendRuntimeInput(
        &app.model,
        .{
            .pane_id = pane,
            .bytes = &source,
        },
    );
    try flush(app);
    try std.testing.expectError(error.DriverBusy, capture.drain(app));
    try std.testing.expectEqual(@as(u8, 2), app.model.to_runtime.len);
    try std.testing.expect(!app.model.to_runtime.inFlight());
    @memset(&source, 'y');
    capture.reject = false;

    try app.model.to_runtime.push(
        .{
            .detach_pane = .{
                .pane_id = pane,
            },
        },
    );
    try flush(app);
    try capture.drain(app);
    const first = try core.decodeClient(capture.payload);
    try std.testing.expect(first == .pane_input);
    try std.testing.expectEqual(pane, first.pane_input.pane_id);
    try std.testing.expectEqualStrings("x" ** data.input_limits.max_encoded_bytes, first.pane_input.bytes);
    try app.model.to_runtime.finishSend({});
    try flush(app);
    try capture.drain(app);
    const second = try core.decodeClient(capture.payload);
    try std.testing.expect(second == .pane_input);
    try std.testing.expectEqualStrings("x", second.pane_input.bytes);
    try app.model.to_runtime.finishSend({});
    try flush(app);
    try capture.drain(app);
    const third = try core.decodeClient(capture.payload);
    try std.testing.expect(third == .detach_pane);
    try std.testing.expectEqual(pane, third.detach_pane.pane_id);
    try app.model.to_runtime.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), app.model.to_runtime.len);

    while (app.model.to_runtime.hasCapacity()) {
        try app.model.to_runtime.push(
            .{
                .detach_pane = .{
                    .pane_id = pane,
                },
            },
        );
    }

    const sends = capture.sends;
    try std.testing.expectError(error.ClientOutboxFull, app.model.to_runtime.push(
        .{
            .detach_pane = .{
                .pane_id = pane,
            },
        },
    ));
    try std.testing.expectEqual(sends, capture.sends);
    try std.testing.expect(!app.model.to_runtime.inFlight());
}

/// Owned request deliveries roll back only their own correlation when the outbox is full.
/// Example: `try client_tests.rollBackFullOutbox(sendTabRenameRequest, sendCreateTabRequest);`
pub fn rollBackFullOutbox(comptime rename_tab: fn (*data.ClientModel, core.RenameTab, data.RequestsContinuation) anyerror!void, comptime create_tab: fn (*data.ClientModel, core.CreateTab) anyerror!void) !void {
    const app = try std.testing.allocator.create(Client);
    defer std.testing.allocator.destroy(app);
    app.model = data.ClientModel.init(std.testing.allocator, true);
    defer app.model.deinit();
    app.host_input_source = .{
        .context = app,
        .route_prompt_bytes_fn = undefined,
    };

    app.model.request_lifecycle = .{};
    app.model.to_runtime = try .init(std.testing.allocator);
    defer app.model.to_runtime.deinit(std.testing.allocator);
    const pane_id: core.PaneId = @enumFromInt(1);
    const tab_location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(1),
    };

    const retained = try app.model.request_lifecycle.nextId();
    try app.model.request_lifecycle.tracker.add(retained, .notification);
    while (app.model.to_runtime.hasCapacity()) {
        try app.model.to_runtime.push(
            .{
                .detach_pane = .{
                    .pane_id = pane_id,
                },
            },
        );
    }

    const queued = app.model.to_runtime.len;

    const Delivery = enum { tab_rename, workspace_rename, tab_create, notification };
    for (std.enums.values(Delivery)) |delivery| {
        const request_id = try app.model.request_lifecycle.nextId();
        const location = tab_location;
        const result: anyerror!void = switch (delivery) {
            .tab_rename => rename_tab(
                &app.model,
                .{
                    .request_id = request_id,
                    .location = location,
                    .label = "renamed",
                },
                .{
                    .rename_tab = location,
                },
            ),
            .workspace_rename => workspace_rename.sendWorkspaceRenameRequest(
                &app.model,
                .{
                    .request_id = request_id,
                    .workspace = location.workspace,
                    .name = "renamed",
                },
            ),
            .tab_create => create_tab(
                &app.model,
                .{
                    .request_id = request_id,
                    .workspace = location.workspace,
                    .size = .{
                        .cols = 80,
                        .rows = 24,
                    },
                    .launch = .{
                        .cwd = "/",
                        .arguments = &.{},
                    },
                },
            ),
            .notification => block: {
                _ = actions.executeAction(
                    app,
                    .{
                        .notification = try data.Notification.init(
                            .{
                                .title = "finished",
                                .message = "",
                            },
                        ),
                    },
                    .effect,
                ) catch |err| break :block err;
                break :block {};
            },
        };

        try std.testing.expectError(error.ClientOutboxFull, result);
        try std.testing.expect(app.model.request_lifecycle.tracker.take(request_id) == null);
        try std.testing.expectEqual(@as(usize, 1), app.model.request_lifecycle.tracker.count);
        try std.testing.expectEqual(queued, app.model.to_runtime.len);
    }

    try std.testing.expect(app.model.request_lifecycle.tracker.take(retained).? == .notification);
}

/// Stale sidebar commits must fail before accessing any host resource.
/// Example: `try client_tests.rejectStaleSidebarCommits(deliverSidebarLayout);`
pub fn rejectStaleSidebarCommits(comptime deliver: fn (*Client, data.SidebarLayout) anyerror!void) !void {
    const app = try std.testing.allocator.create(Client);
    defer std.testing.allocator.destroy(app);
    // Uninitialized ports make accidental delivery of a rejected commit invalid.
    app.model = data.ClientModel.init(std.testing.allocator, true);
    defer app.model.deinit();
    const committed = data.sidebar.toggle(&app.model);

    var stale = committed;
    stale.chrome_revision -= 1;
    try std.testing.expectError(error.StaleSidebarLayout, deliver(app, stale));
    stale = committed;
    stale.visible = !committed.visible;
    try std.testing.expectError(error.StaleSidebarLayout, deliver(app, stale));
    stale = committed;
    stale.width += 1;
    try std.testing.expectError(error.StaleSidebarLayout, deliver(app, stale));
}

/// A retained-graphics store that holds nothing, for tests that only flush.
const no_graphics: GraphicsRetention = .{
    .context = undefined,
    .apply_fn = NoGraphics.apply,
    .clear_pane_fn = NoGraphics.clearPane,
    .set_pane_visible_fn = NoGraphics.setPaneVisible,
    .pane_visible_fn = NoGraphics.paneVisible,
    .has_pane_graphics_fn = NoGraphics.paneVisible,
    .ingress_version_fn = NoGraphics.ingressVersion,
    .peek_credit_fn = NoGraphics.peekCredit,
    .consume_credit_fn = NoGraphics.consumeCredit,
};

/// A retained-graphics store that takes every message, for tests that
/// deliver graphics without keeping them.
const accepting_graphics: GraphicsRetention = .{
    .context = undefined,
    .apply_fn = NoGraphics.accept,
    .clear_pane_fn = NoGraphics.clearPane,
    .set_pane_visible_fn = NoGraphics.setPaneVisible,
    .pane_visible_fn = NoGraphics.paneVisible,
    .has_pane_graphics_fn = NoGraphics.paneVisible,
    .ingress_version_fn = NoGraphics.ingressVersion,
    .peek_credit_fn = NoGraphics.peekCredit,
    .consume_credit_fn = NoGraphics.consumeCredit,
};

const NoGraphics = struct {
    fn accept(_: *anyopaque, _: data.PaneGraphicsCommand) !void {}

    fn apply(_: *anyopaque, _: data.PaneGraphicsCommand) !void {
        return error.UnexpectedGraphics;
    }

    fn clearPane(_: *anyopaque, _: core.PaneId) void {}

    fn setPaneVisible(_: *anyopaque, _: core.PaneId, _: bool) !void {}

    fn paneVisible(_: *anyopaque, _: core.PaneId) bool {
        return false;
    }

    fn ingressVersion(_: *anyopaque) u64 {
        return 0;
    }

    fn peekCredit(_: *anyopaque) ?Credit {
        return null;
    }

    fn consumeCredit(_: *anyopaque, _: Credit) void {}
};

const SocketPair = struct {
    channel: localsocket.SocketChannel,
    peer: localsocket.SocketChannel,
};

fn socketPair() !SocketPair {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }

    return .{
        .channel = .init(.{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .loopback(0) } } }),
        .peer = .init(.{ .socket = .{ .handle = fds[1], .address = .{ .ip4 = .loopback(0) } } }),
    };
}

/// A lost socket leaves the client running and closes once no job uses it;
/// the backoff then connects again and the new session starts fresh.
/// Example: `try client_tests.reconnectAfterLoss(runtime_link.start);`
pub fn reconnectAfterLoss(comptime start: fn (*Client) anyerror!void) !void {
    const gpa = std.testing.allocator;
    const app = try gpa.create(Client);
    defer gpa.destroy(app);

    try app.init(.{
        .gpa = gpa,
        .io = std.testing.io,
        .host_size = .{
            .cols = 40,
            .rows = 10,
            .cell_width_px = 0,
            .cell_height_px = 0,
        },
        .options = .{
            .arguments = &.{"/bin/sh"},
            .cwd = "/",
            .endpoint = "",
            .machine = .{ .local = .{} },
        },
    });
    defer app.deinit();
    app.graphics = no_graphics;
    app.bootstrap = .{
        .graphics_shared = false,
        .client_identity = @enumFromInt(7),
    };

    try start(app);
    try std.testing.expect(app.model.runtime_link.phase == .connecting);
    try std.testing.expect(app.to_background.pop().? == .runtime_connect);

    var first = try socketPair();
    defer first.peer.deinit(std.testing.io);
    app.connect_result = .{ .channel = first.channel };
    try std.testing.expectEqual(@as(?u8, null), try app.update(.{ .runtime_connected = {} }));
    try std.testing.expect(app.model.runtime_link.phase == .connected);
    try std.testing.expect(app.runtime_transport.receive_pending);
    try std.testing.expect(app.model.to_runtime.inFlight());
    while (app.to_workers.pop()) |_| {}

    try data.workspace_handoff.bootstrap(
        &app.model,
        .{
            .pane_id = @enumFromInt(3),
            .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(2) },
            .size = .{
                .cols = 40,
                .rows = 10,
            },
        },
    );

    try std.testing.expectEqual(@as(?u8, null), try app.update(.{ .server = error.EndOfStream }));
    try std.testing.expect(app.model.runtime_link.phase == .lost);
    try std.testing.expectEqualStrings("EndOfStream", app.model.runtime_link.failure().?);
    try std.testing.expect(app.channel_owned);

    try std.testing.expectEqual(@as(?u8, null), try app.update(.{ .sent = error.BrokenPipe }));
    try std.testing.expect(!app.channel_owned);
    try std.testing.expect(app.runtime_transport.connection == null);
    const retry = app.to_workers.pop().?;
    try std.testing.expect(retry == .timer and retry.timer.kind == .runtime_retry);

    try std.testing.expectEqual(@as(?u8, null), try app.update(.{ .runtime_retry_tick = {} }));
    try std.testing.expect(app.model.runtime_link.phase == .connecting);
    try std.testing.expectEqual(@as(u16, 1), app.model.runtime_link.attempt);
    try std.testing.expect(app.to_background.pop().? == .runtime_connect);

    var second = try socketPair();
    defer second.peer.deinit(std.testing.io);
    app.connect_result = .{ .channel = second.channel };
    try std.testing.expectEqual(@as(?u8, null), try app.update(.{ .runtime_connected = {} }));
    try std.testing.expect(app.model.runtime_link.phase == .connected);
    try std.testing.expectEqual(@as(u32, 2), app.model.runtime_link.sessions);
    try std.testing.expectEqual(@as(usize, 0), app.model.tabs.count);
    try std.testing.expect(app.model.startup.phase == .opening);
    while (app.to_workers.pop()) |_| {}
}

/// A runtime message that stops at a limit resyncs as little as it can: a
/// graphics snapshot, a pane snapshot or a new session. One whose resync
/// cannot be asked for loses the link; past the budget a pane's graphics
/// stay paused and anything else gives the link up naming the limit, until
/// the person retries.
/// Example: `try client_tests.recoverLimitedMessages(limit_reached.recover, limit_reached.resumeGraphics);`
pub fn recoverLimitedMessages(comptime recover: fn (*Client, RuntimeResync, anyerror) anyerror!void, comptime limit_reached_resume: fn (*Client) anyerror!void) !void {
    const gpa = std.testing.allocator;
    const app = try gpa.create(Client);
    defer gpa.destroy(app);

    try app.init(.{
        .gpa = gpa,
        .io = std.testing.io,
        .host_size = .{
            .cols = 40,
            .rows = 10,
            .cell_width_px = 0,
            .cell_height_px = 0,
        },
        .options = .{
            .arguments = &.{"/bin/sh"},
            .cwd = "/",
            .endpoint = "",
            .machine = .{ .local = .{} },
        },
    });
    defer app.deinit();
    app.graphics = no_graphics;
    app.bootstrap = .{
        .graphics_shared = false,
        .client_identity = @enumFromInt(7),
    };

    const pane_id: core.PaneId = @enumFromInt(3);
    try runtime_link.start(app);
    var first = try connectForLimits(app);
    defer first.deinit(std.testing.io);

    // A graphics limit says the pane's images paused and asks for that
    // pane's graphics snapshot, within the pane's own budget.
    try recover(app, .{ .graphics = pane_id }, error.GraphicsQuotaExceeded);
    try std.testing.expect(app.model.runtime_link.phase == .connected);
    try std.testing.expectEqual(@as(usize, 1), queuedCount(app, .request_graphics_snapshot));
    try std.testing.expectEqualStrings("Images paused in pane 1: shell", app.model.notification_center.itemAt(0).?.title());
    try recover(app, .{ .graphics = pane_id }, error.GraphicsQuotaExceeded);
    try recover(app, .{ .graphics = pane_id }, error.GraphicsQuotaExceeded);
    try recover(app, .{ .graphics = pane_id }, error.GraphicsQuotaExceeded);
    try std.testing.expectEqual(@as(usize, 3), queuedCount(app, .request_graphics_snapshot));
    try std.testing.expectEqual(@as(usize, 1), app.model.graphics_pauses.waiting_count);
    try std.testing.expectEqual(@as(u8, 0), app.model.runtime_link.limit_resyncs);

    // Once its window passes, the paused pane asks again by itself.
    const slot = app.model.graphics_pauses.find(pane_id).?;
    app.model.graphics_pauses.due_ns[slot] -|= runtime_link.healthy_after_ns;
    try limit_reached_resume(app);
    try std.testing.expectEqual(@as(usize, 4), queuedCount(app, .request_graphics_snapshot));
    try std.testing.expectEqual(@as(usize, 0), app.model.graphics_pauses.waiting_count);

    // A pane frame asks for that pane's snapshot, from the link's budget.
    try recover(app, .{ .pane = pane_id }, error.ClientOutboxFull);
    try recover(app, .{ .pane = pane_id }, error.ClientOutboxFull);
    try recover(app, .{ .pane = pane_id }, error.ClientOutboxFull);
    try std.testing.expect(app.model.runtime_link.phase == .connected);
    try std.testing.expectEqual(@as(usize, 3), queuedCount(app, .request_snapshot));

    // Anything else past the budget gives the link up, with no retry.
    try recover(app, .session, error.TooManyTabs);
    try std.testing.expect(app.model.runtime_link.phase == .failed);
    try std.testing.expectEqualStrings("TooManyTabs: limit reached", app.model.runtime_link.failure().?);
    while (app.to_workers.pop()) |job| {
        try std.testing.expect(!(job == .timer and job.timer.kind == .runtime_retry));
    }

    // Retrying by hand counts limits anew; a resync it cannot ask for loses
    // the link rather than leave it connected with a stale replica.
    try closeForLimits(app);
    try runtime_link.retryNow(app);
    try std.testing.expectEqual(@as(u8, 0), app.model.runtime_link.limit_resyncs);
    var second = try connectForLimits(app);
    defer second.deinit(std.testing.io);
    while (app.model.to_runtime.hasCapacity()) {
        try app.model.to_runtime.push(.{ .request_graphics_snapshot = .{ .pane_id = pane_id } });
    }
    try recover(app, .{ .pane = pane_id }, error.ClientOutboxFull);
    try std.testing.expect(app.model.runtime_link.phase == .lost);

    // A new session is a lost link that retries.
    try closeForLimits(app);
    try runtime_link.retryNow(app);
    var third = try connectForLimits(app);
    defer third.deinit(std.testing.io);
    try recover(app, .session, error.TooManyTabs);
    try std.testing.expect(app.model.runtime_link.phase == .lost);
    try closeForLimits(app);
}

/// Completes the connection `app` queued over a fresh socket pair, gives
/// it one pane, 3, and returns the runtime's end of the pair.
fn connectForLimits(app: *Client) !localsocket.SocketChannel {
    _ = app.to_background.pop().?;
    const pair = try socketPair();
    app.connect_result = .{ .channel = pair.channel };
    _ = try app.update(.{ .runtime_connected = {} });
    while (app.to_workers.pop()) |_| {}

    try data.workspace_handoff.bootstrap(
        &app.model,
        .{
            .pane_id = @enumFromInt(3),
            .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(2) },
            .size = .{
                .cols = 40,
                .rows = 10,
            },
        },
    );

    return pair.peer;
}

/// How many messages of one kind wait in `app`'s outbox.
fn queuedCount(app: *const Client, tag: std.meta.Tag(data.outbox_support.Message)) usize {
    const outbox = &app.model.to_runtime;
    var count: usize = 0;
    for (0..outbox.len) |offset| {
        const index = (@as(usize, outbox.head) + offset) % outbox.items.len;
        if (outbox.items[index] == tag) {
            count += 1;
        }
    }

    return count;
}

/// Lets the closed socket's pending read and write finish.
fn closeForLimits(app: *Client) !void {
    _ = try app.update(.{ .server = error.EndOfStream });
    _ = try app.update(.{ .sent = error.BrokenPipe });
    while (app.to_workers.pop()) |_| {}
}

/// Each pane whose images pause gets one notice naming it by its number
/// and program, which focuses it when clicked; further reaches of a paused
/// pane only count, so `telar diagnostics limits` still sees every one.
/// Example: `try client_tests.noticePausedPanes(limit_reached.recover);`
pub fn noticePausedPanes(comptime recover: fn (*Client, RuntimeResync, anyerror) anyerror!void) !void {
    const gpa = std.testing.allocator;
    const app = try gpa.create(Client);
    defer gpa.destroy(app);

    try initForLimits(app);
    defer app.deinit();
    var runtime = try connectForLimits(app);
    defer runtime.deinit(std.testing.io);
    const second = try splitForLimits(app);
    _ = app.model.panes.find(second).?.setForegroundName("vim");

    try reachImageLimit(recover, app);
    try reachImageLimit(recover, app);
    try std.testing.expectEqual(@as(usize, 1), noticeCount(app));
    try recover(
        app,
        .{
            .graphics = second,
        },
        error.GraphicsQuotaExceeded,
    );
    try std.testing.expectEqual(@as(usize, 2), noticeCount(app));
    try expectNotice(
        app,
        "Images paused in pane 1: shell",
        limits_pane,
    );
    try expectNotice(
        app,
        "Images paused in pane 2: vim",
        second,
    );

    const reached = app.model.limit_reaches.find("GraphicsQuotaExceeded").?;
    try std.testing.expectEqual(@as(u64, 3), app.model.limit_reaches.hits[reached]);
    try std.testing.expect(app.model.graphics_pauses.contains(limits_pane));
    try std.testing.expect(app.model.graphics_pauses.contains(second));
    try data.model_invariants.check(&app.model);
    try closeForLimits(app);
}

/// A waiting pane resumes without runtime traffic: its timer is armed for
/// its due time and asks when it fires, then idles while nothing waits;
/// focusing the pane asks once its base window passed, before its doubled
/// wait ends.
/// Example: `try client_tests.resumeWithoutTraffic(limit_reached.recover, limit_reached.finishResumeTick);`
pub fn resumeWithoutTraffic(comptime recover: fn (*Client, RuntimeResync, anyerror) anyerror!void, comptime finish_tick: fn (*Client, anyerror!void) anyerror!void) !void {
    const gpa = std.testing.allocator;
    const app = try gpa.create(Client);
    defer gpa.destroy(app);

    try initForLimits(app);
    defer app.deinit();
    var runtime = try connectForLimits(app);
    defer runtime.deinit(std.testing.io);
    const second = try splitForLimits(app);
    _ = try pane_focus.applyPaneFocus(
        app,
        .{
            .target = .{
                .pane_id = second,
            },
            .area = app.geometry().area,
        },
    );

    for (0..4) |_| {
        try reachImageLimit(recover, app);
    }

    const pauses = &app.model.graphics_pauses;
    var slot = pauses.find(limits_pane).?;
    try std.testing.expectEqual(@as(usize, 1), pauses.waiting_count);
    try std.testing.expect(armedTimer(app, .graphics_resume));
    try std.testing.expectEqual(pauses.due_ns[slot], app.graphics_resume.deadline_ns.load(.acquire));

    // The timer fires once the wait passed and asks; nothing else waits,
    // so no timer follows.
    pauses.due_ns[slot] = 0;
    try finish_tick(app, {});
    try std.testing.expectEqual(@as(usize, 4), queuedCount(app, .request_graphics_snapshot));
    try std.testing.expectEqual(@as(usize, 0), pauses.waiting_count);
    try std.testing.expect(!app.graphics_resume.pending);
    try std.testing.expect(!armedTimer(app, .graphics_resume));

    // Waiting again, the pane is focused once its base window passed.
    for (0..3) |_| {
        try reachImageLimit(recover, app);
    }

    slot = pauses.find(limits_pane).?;
    try std.testing.expectEqual(@as(usize, 1), pauses.waiting_count);
    pauses.since_ns[slot] -|= runtime_link.healthy_after_ns;
    try std.testing.expect(pauses.due_ns[slot] > pacing.clock.monotonic(app.io));
    _ = try pane_focus.applyPaneFocus(
        app,
        .{
            .target = .{
                .pane_id = limits_pane,
            },
            .area = app.geometry().area,
        },
    );
    try std.testing.expectEqual(@as(usize, 7), queuedCount(app, .request_graphics_snapshot));
    try std.testing.expectEqual(@as(usize, 0), pauses.waiting_count);
    try data.model_invariants.check(&app.model);
    try closeForLimits(app);
}

/// A pause ends when a graphics snapshot of the pane applies without the
/// pane reaching its limit again, and a new session drops every pause. A
/// table that is somehow full gives up its oldest row and asks that
/// pane's snapshot, so no pane stays paused without a resume on the way.
/// Example: `try client_tests.endGraphicsPauses(limit_reached.recover);`
pub fn endGraphicsPauses(comptime recover: fn (*Client, RuntimeResync, anyerror) anyerror!void) !void {
    const gpa = std.testing.allocator;
    const app = try gpa.create(Client);
    defer gpa.destroy(app);

    try initForLimits(app);
    defer app.deinit();
    app.graphics = accepting_graphics;
    var first = try connectForLimits(app);
    defer first.deinit(std.testing.io);
    const pauses = &app.model.graphics_pauses;

    // A snapshot that applies whole ends the pause, and the window stops
    // marking the pane.
    try reachImageLimit(recover, app);
    const marked = app.model.pane_graphics_revision;
    try receiveSnapshot(app, .begin);
    try std.testing.expect(pauses.contains(limits_pane));
    try receiveSnapshot(app, .end);
    try std.testing.expect(!pauses.contains(limits_pane));
    try std.testing.expect(app.model.pane_graphics_revision != marked);

    // A snapshot the pane's limit stops again keeps the pause.
    try reachImageLimit(recover, app);
    try receiveSnapshot(app, .begin);
    try reachImageLimit(recover, app);
    try receiveSnapshot(app, .end);
    try std.testing.expect(pauses.contains(limits_pane));
    try data.model_invariants.check(&app.model);

    // A full table gives up its oldest row, a waiting one, and asks that
    // pane's snapshot at once.
    pauses.* = .{};
    for (0..data.GraphicsPauses.capacity) |number| {
        const row = pauses.add(@enumFromInt(1000 + number), number);
        pauses.setWaiting(row, true);
    }

    const asked = queuedCount(app, .request_graphics_snapshot);
    try reachImageLimit(recover, app);
    try std.testing.expectEqual(data.GraphicsPauses.capacity, pauses.count);
    try std.testing.expect(!pauses.contains(@enumFromInt(1000)));
    try std.testing.expect(pauses.contains(limits_pane));
    try std.testing.expectEqual(data.GraphicsPauses.capacity - 1, pauses.waiting_count);
    try std.testing.expectEqual(asked + 2, queuedCount(app, .request_graphics_snapshot));
    try std.testing.expect(queuedSnapshotFor(app, @enumFromInt(1000)));

    // A new session starts with no pause.
    try closeForLimits(app);
    try runtime_link.retryNow(app);
    var second = try connectForLimits(app);
    defer second.deinit(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), pauses.count);
    try std.testing.expectEqual(@as(usize, 0), pauses.waiting_count);
    try data.model_invariants.check(&app.model);
    try closeForLimits(app);
}

/// Each window a pause ends waiting doubles the next wait, up to its cap.
/// A pane that pauses again soon after a snapshot ended its pause goes on
/// with that backoff and no second notice; one that pauses after a healthy
/// window starts a new pause that waits one window again.
/// Example: `try client_tests.backOffPausedPanes(limit_reached.recover, limit_reached.resumeGraphics, limit_reached.receiveGraphicsSnapshot);`
pub fn backOffPausedPanes(comptime recover: fn (*Client, RuntimeResync, anyerror) anyerror!void, comptime limit_reached_resume: fn (*Client) anyerror!void, comptime receive_snapshot: fn (*Client, core.Snapshot) anyerror!void) !void {
    const gpa = std.testing.allocator;
    const app = try gpa.create(Client);
    defer gpa.destroy(app);

    try initForLimits(app);
    defer app.deinit();
    var runtime = try connectForLimits(app);
    defer runtime.deinit(std.testing.io);
    const pauses = &app.model.graphics_pauses;
    const longest_wait_ns = 16 * std.time.ns_per_min;

    var window_ns: u64 = runtime_link.healthy_after_ns;
    for (0..6) |round| {
        const reaches: usize = if (round == 0) 4 else 3;
        for (0..reaches) |_| {
            try reachImageLimit(recover, app);
        }

        const slot = pauses.find(limits_pane).?;
        try std.testing.expect(pauses.waiting[slot]);
        try std.testing.expectEqual(pauses.since_ns[slot] + window_ns, pauses.due_ns[slot]);
        pauses.due_ns[slot] = 0;
        try limit_reached_resume(app);
        try std.testing.expect(!pauses.waiting[slot]);
        window_ns = @min(2 * window_ns, longest_wait_ns);
    }

    try std.testing.expectEqual(longest_wait_ns, window_ns);

    // The pause ends; the next one waits one window again.
    const snapshot: core.Snapshot = .{
        .pane_id = limits_pane,
        .revision = 1,
        .phase = .begin,
    };
    try receive_snapshot(app, snapshot);
    var ended = snapshot;
    ended.phase = .end;
    try receive_snapshot(app, ended);
    try std.testing.expect(!pauses.contains(limits_pane));
    const notices = app.model.notification_center.count;
    try reachImageLimit(recover, app);
    try std.testing.expect(pauses.contains(limits_pane));
    try std.testing.expectEqual(notices, app.model.notification_center.count);
    const kept = pauses.find(limits_pane).?;
    try std.testing.expect(pauses.backoff[kept] > 1);

    try receive_snapshot(app, snapshot);
    try receive_snapshot(app, ended);
    pauses.resumed_ns[kept] = 0;
    for (0..4) |_| {
        try reachImageLimit(recover, app);
    }

    const slot = pauses.find(limits_pane).?;
    try std.testing.expectEqual(@as(u8, 1), pauses.backoff[slot]);
    try std.testing.expectEqual(pauses.since_ns[slot] + runtime_link.healthy_after_ns, pauses.due_ns[slot]);
    try closeForLimits(app);
}

/// The pane `connectForLimits` gives the client.
const limits_pane: core.PaneId = @enumFromInt(3);

/// Delivers one graphics message of `limits_pane` that stopped at its
/// limit.
fn reachImageLimit(comptime recover: fn (*Client, RuntimeResync, anyerror) anyerror!void, app: *Client) !void {
    try recover(
        app,
        .{
            .graphics = limits_pane,
        },
        error.GraphicsQuotaExceeded,
    );
}

/// Initializes `app` for a local machine and starts its link; the caller
/// completes the connection with `connectForLimits`.
fn initForLimits(app: *Client) !void {
    try app.init(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .host_size = .{
            .cols = 40,
            .rows = 10,
            .cell_width_px = 0,
            .cell_height_px = 0,
        },
        .options = .{
            .arguments = &.{"/bin/sh"},
            .cwd = "/",
            .endpoint = "",
            .machine = .{ .local = .{} },
        },
    });
    errdefer app.deinit();
    app.graphics = no_graphics;
    app.bootstrap = .{
        .graphics_shared = false,
        .client_identity = @enumFromInt(7),
    };

    try runtime_link.start(app);
}

/// Splits `limits_pane` and returns the new pane, the tab's second.
fn splitForLimits(app: *Client) !core.PaneId {
    const second: core.PaneId = @enumFromInt(4);
    const tab = app.model.tabs.active;
    try data.pane_split.split(
        &app.model,
        tab,
        .{
            .existing_pane = limits_pane,
            .new_pane = second,
            .location = app.model.tabs.location[tab],
            .axis = .horizontal,
            .area = app.geometry().area,
        },
    );

    return second;
}

/// Delivers one phase of a graphics snapshot of `limits_pane` as the
/// runtime sends it.
fn receiveSnapshot(app: *Client, phase: @FieldType(core.Snapshot, "phase")) !void {
    const message: core.ServerMessage = .{
        .graphics_snapshot = .{
            .pane_id = limits_pane,
            .revision = 1,
            .phase = phase,
        },
    };
    _ = try runtime_messages.receiveServerMessage(app, &message);
}

fn noticeCount(app: *const Client) usize {
    var count: usize = 0;
    while (app.model.notification_center.itemAt(count)) |_| {
        count += 1;
    }

    return count;
}

/// Fails unless a notice titled `title` focuses `pane_id` when clicked.
fn expectNotice(app: *const Client, title: []const u8, pane_id: core.PaneId) !void {
    var index: usize = 0;
    while (app.model.notification_center.itemAt(index)) |item| : (index += 1) {
        if (std.mem.eql(u8, item.title(), title)) {
            try std.testing.expect(item.level == .warning);
            try std.testing.expect(item.target == .focus_pane and item.target.focus_pane == pane_id);
            return;
        }
    }

    return error.TestExpectedNotice;
}

/// Pops every queued job and returns whether a timer of `kind` was among
/// them.
fn armedTimer(app: *Client, kind: Job.Kind) bool {
    var armed = false;
    while (app.to_workers.pop()) |job| {
        if (job == .timer and job.timer.kind == kind) {
            armed = true;
        }
    }

    return armed;
}

/// Whether the outbox holds a graphics snapshot request for `pane_id`.
fn queuedSnapshotFor(app: *const Client, pane_id: core.PaneId) bool {
    const outbox = &app.model.to_runtime;
    for (0..outbox.len) |offset| {
        const index = (@as(usize, outbox.head) + offset) % outbox.items.len;
        switch (outbox.items[index]) {
            .request_graphics_snapshot => |request| {
                if (request.pane_id == pane_id) {
                    return true;
                }
            },
            else => {},
        }
    }

    return false;
}

/// A failed attempt keeps the client, shows the report and waits to retry;
/// retrying now connects before the wait ends.
/// Example: `try client_tests.failedAttemptWaits(runtime_link.start, runtime_link.retryNow);`
pub fn failedAttemptWaits(comptime start: fn (*Client) anyerror!void, comptime retry_now: fn (*Client) anyerror!void) !void {
    const gpa = std.testing.allocator;
    const app = try gpa.create(Client);
    defer gpa.destroy(app);

    try app.init(.{
        .gpa = gpa,
        .io = std.testing.io,
        .host_size = .{
            .cols = 40,
            .rows = 10,
            .cell_width_px = 0,
            .cell_height_px = 0,
        },
        .options = .{
            .arguments = &.{},
            .cwd = "",
            .endpoint = "",
            .machine = .{ .remote = .{ .destination = "dev@box" } },
        },
    });
    defer app.deinit();
    app.graphics = no_graphics;

    try start(app);
    try std.testing.expectEqualStrings("dev@box", app.model.runtime_link.target());
    _ = app.to_background.pop().?;

    const report = "ssh: Could not resolve hostname box";
    @memcpy(app.connect_report.bytes[0..report.len], report);
    app.connect_report.len = report.len;
    try std.testing.expectEqual(@as(?u8, null), try app.update(.{ .runtime_connected = error.RemoteEndpointUnavailable }));
    try std.testing.expect(app.model.runtime_link.phase == .lost);
    try std.testing.expectEqualStrings(report, app.model.runtime_link.failure().?);
    const retry = app.to_workers.pop().?;
    try std.testing.expect(retry == .timer and retry.timer.kind == .runtime_retry);

    try retry_now(app);
    try std.testing.expect(app.model.runtime_link.phase == .connecting);
    try std.testing.expect(app.to_background.pop().? == .runtime_connect);
}

/// A hidden machine defers its first pane, opens it when shown, and leaves
/// its workspace when hidden again, reopening it on the next show.
/// Example: `try client_tests.hiddenMachineDefersAndLeaves(machine_presentation.show, machine_presentation.hide);`
pub fn hiddenMachineDefersAndLeaves(comptime show: fn (*Client) anyerror!void, comptime hide: fn (*Client) anyerror!void) !void {
    const gpa = std.testing.allocator;
    var pair = try socketPair();
    defer pair.channel.deinit(std.testing.io);
    defer pair.peer.deinit(std.testing.io);

    const app = try gpa.create(Client);
    defer gpa.destroy(app);

    try app.init(.{
        .gpa = gpa,
        .io = std.testing.io,
        .connection = &pair.channel,
        .host_size = .{
            .cols = 40,
            .rows = 10,
            .cell_width_px = 0,
            .cell_height_px = 0,
        },
        .options = .{
            .arguments = &.{"/bin/sh"},
            .cwd = "/",
            .endpoint = "",
        },
    });
    defer app.deinit();
    app.graphics = no_graphics;
    app.presented = false;

    var buffer: [256]u8 = undefined;
    const snapshot = try core.encodeClientLayoutSnapshot(&buffer, .{ .restored = false });
    _ = try runtime_messages.handleServerMessage(app, try core.decodeServer(snapshot));
    try std.testing.expect(app.open_deferred);
    try std.testing.expectEqual(@as(u8, 0), app.model.to_runtime.len);

    try show(app);
    try std.testing.expect(!app.open_deferred);
    try std.testing.expect(app.model.to_runtime.peek().?.* == .open_pane);
    app.model.to_runtime.discardQueued();
    app.model.request_lifecycle = .{};

    try data.workspace_handoff.bootstrap(
        &app.model,
        .{
            .pane_id = @enumFromInt(3),
            .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(2) },
            .size = .{
                .cols = 40,
                .rows = 10,
            },
        },
    );

    try hide(app);
    try std.testing.expect(app.model.workspace == null);
    const left: core.WorkspaceLocation = .{
        .workspace = @enumFromInt(1),
    };
    try std.testing.expectEqual(@as(?core.WorkspaceLocation, left), app.left_workspace);
    try std.testing.expect(app.model.to_runtime.peek().?.* == .detach_pane);
    app.model.to_runtime.discardQueued();

    try show(app);
    try std.testing.expect(app.left_workspace == null);
    try std.testing.expect(app.model.to_runtime.peek().?.* == .open_pane);
    app.model.to_runtime.discardQueued();
}
