//! Test bodies for Client. Private implementations are supplied by the
//! owner's test declarations as concrete compile-time functions.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const Client = @import("Client.zig");
const Job = @import("Job.zig").Job;
const GraphicsRetention = @import("../graphics/GraphicsRetention.zig");
const Credit = @import("../graphics/Credit.zig");
const actions = @import("../input/actions.zig");
const change_review = @import("../change_review/change_review.zig");
const runtime_io = @import("../connection/runtime_io.zig");
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

    const stale_capabilities = (try data.host_capabilities.observe(&app.model, 
        .{
            .images = .supported,
        },
    )).?;
    _ = try data.host_capabilities.observe(&app.model, 
        .{
            .pointer_pixels = .supported,
        },
    );
    const stale_size = (try data.host_capabilities.reconcile(&app.model, 
        .{
            .capabilities = app.model.host.host_capabilities,
            .size = .{
                .cols = 100,
                .rows = 30,
            },
        },
    )).?;
    _ = try data.host_capabilities.reconcile(&app.model, 
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

/// A client with only the transport and outbox a transport test touches.
fn transportClient(send_buffer: []u8) !*Client {
    const app = try std.testing.allocator.create(Client);
    errdefer std.testing.allocator.destroy(app);
    app.io = std.testing.io;
    app.to_workers = .{};
    app.to_background = .{};
    app.graphics = no_graphics;
    app.model.to_runtime = try .init(std.testing.allocator);
    app.runtime_transport = .{
        .connection = undefined,
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

/// Change review operation accepts terminal panes and rejects replaced attachments.
/// Example: `try client_tests.rejectReplacedReviewAttachment(openChangeReviewSession, changeReviewOperation, applyChangeReviewResponse);`
pub fn rejectReplacedReviewAttachment(comptime open_session: fn (*data.ClientModel, core.PaneId) anyerror!void, comptime operation: fn (*data.ClientModel, u64) anyerror!data.ChangeReviewOperation, comptime apply_response: fn (*data.ClientModel, data.ChangeReviewOperation, core.ChangeReviewSnapshotView) anyerror!bool) !void {
    const app = try std.testing.allocator.create(Client);
    const model = &app.model;
    defer std.testing.allocator.destroy(app);
    model.* = data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    app.model.change_review = .{};
    const session = &app.model.change_review;
    const pane_id: core.PaneId = @enumFromInt(1);
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(1),
    };

    try data.workspace_handoff.bootstrap(
        model,
        .{
            .pane_id = pane_id,
            .location = location,
            .size = .{
                .cols = 20,
                .rows = 5,
            },
        },
    );
    const pane = model.panes.find(pane_id).?;
    _ = pane.identify(3);
    try open_session(&app.model, pane_id);
    try std.testing.expect(change_review.isChangeReviewAttached(&app.model));
    const pending_owner = try operation(&app.model, 0);
    session.begin(@enumFromInt(21));
    try std.testing.expectError(error.ChangeReviewRequestPending, operation(&app.model, 0));
    const response: core.ChangeReviewSnapshotView = .{
        .request_id = @enumFromInt(21),
        .pane_id = pane_id,
        .pane_generation = 3,
        .edition_id = 1,
        .patch = "immutable",
    };

    pane.attachment_generation += 1;
    try std.testing.expect(!change_review.isChangeReviewAttached(&app.model));
    try std.testing.expect(!try apply_response(
        &app.model,
        pending_owner,
        response,
    ));
    try std.testing.expect(!session.loaded);
    try std.testing.expect(session.errorSlice().len > 0);
}

/// Change review operation updates closed review availability without opening or querying a view.
/// Example: `try client_tests.retainReviewAvailability(openChangeReviewSession, changeReviewChanged);`
pub fn retainReviewAvailability(comptime open_session: fn (*data.ClientModel, core.PaneId) anyerror!void, comptime changed: fn (*data.ClientModel, core.ChangeReviewChanged) bool) !void {
    const app = try std.testing.allocator.create(Client);
    const model = &app.model;
    defer std.testing.allocator.destroy(app);
    model.* = data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    app.model.change_review = .{};
    const session = &app.model.change_review;
    const pane_id: core.PaneId = @enumFromInt(1);
    const location: core.TabLocation = .{
        .workspace = .{
            .workspace = @enumFromInt(1),
        },
        .tab_id = @enumFromInt(1),
    };

    try data.workspace_handoff.bootstrap(
        model,
        .{
            .pane_id = pane_id,
            .location = location,
            .size = .{
                .cols = 20,
                .rows = 5,
            },
        },
    );
    const pane = model.panes.find(pane_id).?;
    _ = pane.identify(3);
    var notification: core.ChangeReviewChanged = .{
        .pane_id = pane_id,
        .pane_generation = 3,
        .session = "hook-session",
        .latest_edition_id = 1,
    };

    const revision = model.pane_metadata_revision;
    try std.testing.expect(changed(&app.model, notification));
    try std.testing.expect(model.pane_metadata_revision != revision);
    try std.testing.expect(pane.hasChangeReview());
    try std.testing.expect(session.owner == null);
    try std.testing.expect(!session.needsRefresh());
    try std.testing.expect(!changed(&app.model, notification));

    try open_session(&app.model, pane_id);
    notification.latest_edition_id = 2;
    try std.testing.expect(changed(&app.model, notification));
    try std.testing.expect(session.needsRefresh());
    change_review.closeChangeReview(&app.model);
    try std.testing.expect(pane.hasChangeReview());
    notification.session = "next-hook-session";
    notification.latest_edition_id = 0;
    try std.testing.expect(changed(&app.model, notification));
    try std.testing.expect(!pane.hasChangeReview());
    try std.testing.expect(!session.needsRefresh());
    notification.pane_generation += 1;
    notification.latest_edition_id = 1;
    try std.testing.expect(!changed(&app.model, notification));
    try std.testing.expect(!pane.hasChangeReview());
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

const NoGraphics = struct {
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
