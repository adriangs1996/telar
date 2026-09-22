//! Test bodies for AttachedClient. Private implementations are supplied by the
//! owner's test declarations as concrete compile-time functions.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const AttachedClient = @import("AttachedClient.zig");
const ModelType = @import("model/Model.zig");
const RuntimeTransportState = @import("connection/RuntimeTransportState.zig");
const TransportDriverType = @import("connection/TransportDriver.zig");

/// Layout export decodes to the same active pane and split tree.
/// Example: `try attached_client_tests.layoutRoundTrip(writeCommandLayout);`
pub fn layoutRoundTrip(comptime write_layout: fn (*const AttachedClient, *core.ClientCommand) anyerror!void) !void {
    var app: AttachedClient = undefined;
    app.model = ModelType.init(std.testing.allocator, true);
    defer app.model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(2),
    };

    try app.model.workspace.bootstrap(
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

    try write_layout(&app, &reply);
    var bytes: [core.ClientCommand.capacity / 2]u8 = undefined;
    const decoded = try core.decodeServer(try std.fmt.hexToBytes(&bytes, reply.text()));
    try std.testing.expectEqualDeep(location, decoded.client_layout_snapshot.active_tab.?);
    var tabs = decoded.client_layout_snapshot.tabs();
    const tab = (try tabs.next()).?;
    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(3)), tab.focused_pane);
    try std.testing.expect(try tabs.next() == null);
}

/// Host resources reject empty and stale commits before calling ports.
/// Example: `try attached_client_tests.rejectStaleHostCommits(deliverHostCommit);`
pub fn rejectStaleHostCommits(comptime deliver: fn (*AttachedClient, data.HostCommit) anyerror!void) !void {
    const app = try std.testing.allocator.create(AttachedClient);
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

    const stale_capabilities = (try app.model.observeHostCapability(
        .{
            .images = .supported,
        },
    )).?;
    _ = try app.model.observeHostCapability(
        .{
            .pointer_pixels = .supported,
        },
    );
    const stale_size = (try app.model.reconcileHost(
        .{
            .capabilities = app.model.hostCapabilities(),
            .size = .{
                .cols = 100,
                .rows = 30,
            },
        },
    )).?;
    _ = try app.model.reconcileHost(
        .{
            .capabilities = app.model.hostCapabilities(),
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

/// Transport scheduling releases rejected reservations and retries queued frames in order.
/// Example: `try attached_client_tests.retryTransportScheduling(startRuntimeSend);`
pub fn retryTransportScheduling(comptime start_send: fn (*AttachedClient) anyerror!void) !void {
    const Driver = struct {
        reject: bool = true,
        reads: usize = 0,
        sends: usize = 0,
        payload: []const u8 = &.{},

        fn read(raw: *anyopaque, state: *RuntimeTransportState) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            try std.testing.expect(state.receive_pending);

            if (self.reject) {
                return error.DriverBusy;
            }
        }

        fn send(raw: *anyopaque, state: *RuntimeTransportState, payload: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sends += 1;
            self.payload = payload;
            try std.testing.expect(state.outbox.inFlight());

            if (self.reject) {
                return error.DriverBusy;
            }
        }
    };

    var capture: Driver = .{};
    const driver: TransportDriverType = .{
        .context = &capture,
        .start_read_fn = Driver.read,
        .start_send_fn = Driver.send,
    };

    var send_buffer: [64]u8 = undefined;
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    app.transport_driver = driver;
    const state = &app.runtime_transport;
    state.* = .{
        .connection = undefined,
        .send_buffer = &send_buffer,
        .receive_buffer = &.{},
        .read_buffer = &.{},
    };

    try std.testing.expectError(error.DriverBusy, app.startRuntimeRead());
    try std.testing.expect(!state.receive_pending);
    capture.reject = false;
    try app.startRuntimeRead();
    try app.startRuntimeRead();
    try std.testing.expectEqual(@as(usize, 2), capture.reads);
    try std.testing.expectError(error.ReadFailed, state.completeRead(error.ReadFailed));
    try std.testing.expect(!state.receive_pending);
    try app.startRuntimeRead();
    try std.testing.expectEqual(@as(usize, 3), capture.reads);
    state.cancelRead();

    try start_send(app);
    try std.testing.expectEqual(@as(usize, 0), capture.sends);
    try state.outbox.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(1),
            },
        },
    );
    try state.outbox.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(2),
            },
        },
    );
    capture.reject = true;
    try std.testing.expectError(error.DriverBusy, start_send(app));
    try std.testing.expect(!state.outbox.inFlight());
    try std.testing.expectEqual(@as(u8, 2), state.outbox.len);
    const first = send_buffer;
    const first_len = capture.payload.len;
    capture.reject = false;
    try start_send(app);
    try std.testing.expectEqualSlices(
        u8,
        first[0..first_len],
        capture.payload,
    );
    try start_send(app);
    try std.testing.expectEqual(@as(usize, 2), capture.sends);
    try state.outbox.finishSend({});
    try start_send(app);
    try std.testing.expectEqual(@as(usize, 3), capture.sends);
    try std.testing.expect(!std.mem.eql(
        u8,
        first[0..first_len],
        capture.payload,
    ));
    try state.outbox.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), state.outbox.len);
}

/// Enqueue retains copied input after rejected scheduling and preserves order on retry.
/// Example: `try attached_client_tests.retainQueuedInput(startRuntimeSend);`
pub fn retainQueuedInput(comptime start_send: fn (*AttachedClient) anyerror!void) !void {
    const Driver = struct {
        reject: bool = true,
        sends: usize = 0,
        payload: []const u8 = &.{},

        fn read(_: *anyopaque, _: *RuntimeTransportState) !void {
            return error.UnexpectedRead;
        }

        fn send(raw: *anyopaque, _: *RuntimeTransportState, payload: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sends += 1;

            if (self.reject) {
                return error.DriverBusy;
            }

            self.payload = payload;
        }
    };

    var capture: Driver = .{};
    const driver: TransportDriverType = .{
        .context = &capture,
        .start_read_fn = Driver.read,
        .start_send_fn = Driver.send,
    };

    var send_buffer: [data.input_limits.max_encoded_bytes + 64]u8 = undefined;
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    app.transport_driver = driver;
    const state = &app.runtime_transport;
    state.* = .{
        .connection = undefined,
        .send_buffer = &send_buffer,
        .receive_buffer = &.{},
        .read_buffer = &.{},
    };

    const pane: core.PaneId = @enumFromInt(1);
    var source = [_]u8{
        'x',
    } ** (data.input_limits.max_encoded_bytes + 1);

    try std.testing.expectError(error.DriverBusy, app.sendRuntimeInput(
        .{
            .pane_id = pane,
            .bytes = &source,
        },
    ));
    try std.testing.expectEqual(@as(u8, 2), state.outbox.len);
    try std.testing.expect(!state.outbox.inFlight());
    @memset(&source, 'y');
    capture.reject = false;

    try app.sendRuntime(
        .{
            .detach_pane = .{
                .pane_id = pane,
            },
        },
    );
    const first = try core.decodeClient(capture.payload);
    try std.testing.expect(first == .pane_input);
    try std.testing.expectEqual(pane, first.pane_input.pane_id);
    try std.testing.expectEqualStrings("x" ** data.input_limits.max_encoded_bytes, first.pane_input.bytes);
    try state.outbox.finishSend({});
    try start_send(app);
    const second = try core.decodeClient(capture.payload);
    try std.testing.expect(second == .pane_input);
    try std.testing.expectEqualStrings("x", second.pane_input.bytes);
    try state.outbox.finishSend({});
    try start_send(app);
    const third = try core.decodeClient(capture.payload);
    try std.testing.expect(third == .detach_pane);
    try std.testing.expectEqual(pane, third.detach_pane.pane_id);
    try state.outbox.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), state.outbox.len);

    while (state.outbox.hasCapacity()) {
        try state.outbox.push(
            .{
                .detach_pane = .{
                    .pane_id = pane,
                },
            },
        );
    }

    const sends = capture.sends;
    try std.testing.expectError(error.ClientOutboxFull, app.sendRuntime(
        .{
            .detach_pane = .{
                .pane_id = pane,
            },
        },
    ));
    try std.testing.expectEqual(sends, capture.sends);
    try std.testing.expect(!state.outbox.inFlight());
}

/// Change review operation accepts terminal panes and rejects replaced attachments.
/// Example: `try attached_client_tests.rejectReplacedReviewAttachment(openChangeReviewSession, changeReviewOperation, applyChangeReviewResponse);`
pub fn rejectReplacedReviewAttachment(comptime open_session: fn (*AttachedClient, core.PaneId) anyerror!void, comptime operation: fn (*AttachedClient, u64) anyerror!data.ChangeReviewOperation, comptime apply_response: fn (*AttachedClient, data.ChangeReviewOperation, core.ChangeReviewSnapshotView) anyerror!bool) !void {
    const app = try std.testing.allocator.create(AttachedClient);
    const model = &app.model;
    defer std.testing.allocator.destroy(app);
    model.* = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    app.change_review = .{};
    const session = &app.change_review;
    const pane_id: core.PaneId = @enumFromInt(1);
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(1),
    };

    try model.workspace.bootstrap(
        .{
            .pane_id = pane_id,
            .location = location,
            .size = .{
                .cols = 20,
                .rows = 5,
            },
        },
    );
    const pane = model.workspace.findPane(pane_id).?;
    _ = pane.identify(.terminal, 3);
    try open_session(app, pane_id);
    try std.testing.expect(app.isChangeReviewAttached());
    const pending_owner = try operation(app, 0);
    session.begin(@enumFromInt(21));
    try std.testing.expectError(error.ChangeReviewRequestPending, operation(app, 0));
    const response: core.ChangeReviewSnapshotView = .{
        .request_id = @enumFromInt(21),
        .pane_id = pane_id,
        .pane_generation = 3,
        .edition_id = 1,
        .patch = "immutable",
    };

    pane.attachment_generation += 1;
    try std.testing.expect(!app.isChangeReviewAttached());
    try std.testing.expect(!try apply_response(
        app,
        pending_owner,
        response,
    ));
    try std.testing.expect(!session.loaded);
    try std.testing.expect(session.errorSlice().len > 0);
}

/// Change review operation updates closed review availability without opening or querying a view.
/// Example: `try attached_client_tests.retainReviewAvailability(openChangeReviewSession, changeReviewChanged);`
pub fn retainReviewAvailability(comptime open_session: fn (*AttachedClient, core.PaneId) anyerror!void, comptime changed: fn (*AttachedClient, core.ChangeReviewChanged) bool) !void {
    const app = try std.testing.allocator.create(AttachedClient);
    const model = &app.model;
    defer std.testing.allocator.destroy(app);
    model.* = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    app.change_review = .{};
    const session = &app.change_review;
    const pane_id: core.PaneId = @enumFromInt(1);
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(1),
    };

    try model.workspace.bootstrap(
        .{
            .pane_id = pane_id,
            .location = location,
            .size = .{
                .cols = 20,
                .rows = 5,
            },
        },
    );
    const pane = model.workspace.findPane(pane_id).?;
    _ = pane.identify(.terminal, 3);
    var notification: core.ChangeReviewChanged = .{
        .pane_id = pane_id,
        .pane_generation = 3,
        .session = "hook-session",
        .latest_edition_id = 1,
    };

    const revision = model.chrome_revision;
    try std.testing.expect(changed(app, notification));
    try std.testing.expect(model.chrome_revision != revision);
    try std.testing.expect(pane.hasChangeReview());
    try std.testing.expect(session.owner == null);
    try std.testing.expect(!session.needsRefresh());
    try std.testing.expect(!changed(app, notification));

    try open_session(app, pane_id);
    notification.latest_edition_id = 2;
    try std.testing.expect(changed(app, notification));
    try std.testing.expect(session.needsRefresh());
    app.closeChangeReview();
    try std.testing.expect(pane.hasChangeReview());
    notification.session = "next-hook-session";
    notification.latest_edition_id = 0;
    try std.testing.expect(changed(app, notification));
    try std.testing.expect(!pane.hasChangeReview());
    try std.testing.expect(!session.needsRefresh());
    notification.pane_generation += 1;
    notification.latest_edition_id = 1;
    try std.testing.expect(!changed(app, notification));
    try std.testing.expect(!pane.hasChangeReview());
}

/// Owned request deliveries roll back only their own correlation when the outbox is full.
/// Example: `try attached_client_tests.rollBackFullOutbox(sendTabRenameRequest, sendCreateTabRequest, sendAgentPromptRequest);`
pub fn rollBackFullOutbox(comptime rename_tab: fn (*AttachedClient, core.RenameTab, data.RequestsContinuation) anyerror!void, comptime create_tab: fn (*AttachedClient, core.CreateTab) anyerror!void, comptime prompt: fn (*AttachedClient, core.AgentPrompt, data.AgentOperation) anyerror!void) !void {
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    app.model = ModelType.init(std.testing.allocator, true);
    defer app.model.deinit();
    app.host_input_source = .{
        .context = app,
        .resume_read_fn = undefined,
        .route_prompt_bytes_fn = undefined,
        .adopt_bindings_fn = undefined,
    };

    app.request_lifecycle = .{};
    app.runtime_transport.outbox = .{};
    const pane_id: core.PaneId = @enumFromInt(1);
    const tab_location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(1),
    };

    const retained = try app.request_lifecycle.nextId();
    try app.request_lifecycle.tracker.add(retained, .notification);
    while (app.runtime_transport.outbox.hasCapacity()) {
        try app.runtime_transport.outbox.push(
            .{
                .detach_pane = .{
                    .pane_id = pane_id,
                },
            },
        );
    }

    const queued = app.runtime_transport.outbox.len;

    var options: core.AgentOptions = .{
        .effort = try core.AgentEffort.init("test-effort"),
    };

    try options.setModel("test-model");

    const Delivery = enum { tab_rename, workspace_rename, tab_create, agent_prompt, notification };
    for (std.enums.values(Delivery)) |delivery| {
        const request_id = try app.request_lifecycle.nextId();
        const location = tab_location;
        const result: anyerror!void = switch (delivery) {
            .tab_rename => rename_tab(
                app,
                .{
                    .request_id = request_id,
                    .location = location,
                    .label = "renamed",
                },
                .{
                    .rename_tab = location,
                },
            ),
            .workspace_rename => app.sendWorkspaceRenameRequest(
                .{
                    .request_id = request_id,
                    .workspace = location.workspace,
                    .name = "renamed",
                },
            ),
            .tab_create => create_tab(
                app,
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
            .agent_prompt => prompt(
                app,
                .{
                    .request_id = request_id,
                    .pane_id = pane_id,
                    .pane_generation = 1,
                    .text = "review the changes",
                    .options = options,
                },
                .{
                    .pane_id = pane_id,
                    .pane_generation = 1,
                    .attachment_generation = 1,
                    .location = location,
                },
            ),
            .notification => block: {
                _ = app.executeAction(
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
        try std.testing.expect(app.request_lifecycle.tracker.take(request_id) == null);
        try std.testing.expectEqual(@as(usize, 1), app.request_lifecycle.tracker.count);
        try std.testing.expectEqual(queued, app.runtime_transport.outbox.len);
    }

    try std.testing.expect(app.request_lifecycle.tracker.take(retained).? == .notification);
}

/// Stale sidebar commits must fail before accessing any host resource.
/// Example: `try attached_client_tests.rejectStaleSidebarCommits(deliverSidebarLayout);`
pub fn rejectStaleSidebarCommits(comptime deliver: fn (*AttachedClient, data.SidebarLayout) anyerror!void) !void {
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    // Uninitialized ports make accidental delivery of a rejected commit invalid.
    app.model = ModelType.init(std.testing.allocator, true);
    defer app.model.deinit();
    const committed = app.model.toggleSidebar();

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
