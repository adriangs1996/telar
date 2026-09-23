//! Split behavior through the concrete client, its model and real transport.
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const client = @import("telar-client");
const TestHarness = @import("TestHarness.zig");

test "pending pane creation suppresses another split without changing state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    app.options.arguments = &.{"/bin/sh"};
    const before = app.model.version();
    const plan = (try app.requestPaneSplit(
        .{
            .axis = .horizontal,
            .area = app.geometry().area,
        },
    )).?;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, plan.split.target_pane);
    const queued = app.model.to_runtime.len;
    const next_id = app.model.request_lifecycle.next_request_id;

    try std.testing.expect(try app.requestPaneSplit(
        .{
            .axis = .vertical,
            .area = app.geometry().area,
        },
    ) == null);
    try std.testing.expectEqual(queued, app.model.to_runtime.len);
    try std.testing.expectEqual(next_id, app.model.request_lifecycle.next_request_id);
    try std.testing.expectEqualDeep(before, app.model.version());
    try harness.settle();
}

test "split restores the original size when request identity allocation fails" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const before = app.model.version();
    const plan = app.model.planPaneSplit(.{ .axis = .horizontal, .area = app.geometry().area }).?;
    app.model.request_lifecycle.next_request_id = std.math.maxInt(u64);

    try std.testing.expectError(error.RequestIdExhausted, app.requestPaneSplit(
        .{
            .axis = .horizontal,
            .area = app.geometry().area,
        },
    ));
    try std.testing.expect(!app.model.request_lifecycle.tracker.has(.pane_operation));
    try std.testing.expectEqualDeep(before, app.model.version());
    try harness.settle();
    var buffer: [512]u8 = undefined;
    // The restore replaces the provisional resize before the event's write,
    // so the runtime never sees the provisional size.
    const restored = try harness.nextClientMessage(&buffer);
    try std.testing.expect(restored == .pane_resize);
    try std.testing.expectEqualDeep(plan.restore_resize, restored.pane_resize);
}

test "split rejects mismatched runtime confirmations without mutation or delivery" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const plan = app.model.planPaneSplit(.{ .axis = .horizontal, .area = app.geometry().area }).?;
    const before = app.model.version();
    const invalid = [_]core.PaneOpened{
        .{ .request_id = @enumFromInt(4), .pane_id = @enumFromInt(21), .location = TestHarness.bootstrap_location, .created = false },
        .{ .request_id = @enumFromInt(4), .pane_id = TestHarness.bootstrap_pane, .location = TestHarness.bootstrap_location, .created = true },
        .{ .request_id = @enumFromInt(4), .pane_id = @enumFromInt(21), .location = .{ .workspace = TestHarness.bootstrap_location.workspace, .tab_id = @enumFromInt(99) }, .created = true },
    };
    for (invalid) |opened| {
        try app.model.request_lifecycle.tracker.add(opened.request_id, .{ .split = .{
            .target_pane = plan.split.target_pane,
            .location = plan.split.location,
            .axis = plan.split.axis,
            .area = plan.split.area,
        } });

        try std.testing.expectError(error.UnexpectedPane, app.handleServerMessage(
            .{
                .pane_opened = opened,
            },
        ));
        try std.testing.expect(!app.model.request_lifecycle.tracker.has(.pane_operation));
        try std.testing.expectEqualDeep(before, app.model.version());
        try std.testing.expectEqual(@as(usize, 0), app.model.to_runtime.len);
    }
}

test "split retains the runtime creation when confirmation delivery fails" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const plan = app.model.planPaneSplit(.{ .axis = .horizontal, .area = app.geometry().area }).?;
    while (app.model.to_runtime.hasCapacity()) {
        try app.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const before = app.model.version();
    const pane: core.PaneId = @enumFromInt(21);

    const request_id: core.RequestId = @enumFromInt(4);
    try app.model.request_lifecycle.tracker.add(
        request_id,
        .{
            .split = .{
                .target_pane = plan.split.target_pane,
                .location = plan.split.location,
                .axis = plan.split.axis,
                .area = plan.split.area,
            },
        },
    );

    try std.testing.expectError(error.ClientOutboxFull, app.handleServerMessage(
        .{
            .pane_opened = .{
                .request_id = request_id,
                .pane_id = pane,
                .location = plan.split.location,
                .created = true,
            },
        },
    ));
    try std.testing.expect(app.model.panes.find(pane).?.attached);
    try std.testing.expectEqual(pane, app.model.tabs.layout[app.model.tabs.active].focused().?);
    try std.testing.expectEqual(before.panes + 1, app.model.version().panes);
}

test "late split confirmation never detaches a currently represented pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const plan = app.model.planPaneSplit(.{ .axis = .horizontal, .area = app.geometry().area }).?;
    const current: core.PaneId = @enumFromInt(21);
    _ = try harness.addTab(@enumFromInt(2), current);
    try std.testing.expect(data.tab_removal.remove(&app.model, plan.split.location.tab_id));
    const before = app.model.version();

    const request_id: core.RequestId = @enumFromInt(4);
    try app.model.request_lifecycle.tracker.add(
        request_id,
        .{
            .split = .{
                .target_pane = plan.split.target_pane,
                .location = plan.split.location,
                .axis = plan.split.axis,
                .area = plan.split.area,
            },
        },
    );

    try std.testing.expectError(error.StalePaneSplitConfirmation, app.handleServerMessage(
        .{
            .pane_opened = .{
                .request_id = request_id,
                .pane_id = current,
                .location = plan.split.location,
                .created = true,
            },
        },
    ));
    try std.testing.expect(app.model.panes.find(current).?.attached);
    try std.testing.expectEqualDeep(before, app.model.version());
    try std.testing.expectEqual(@as(usize, 0), app.model.to_runtime.len);
}

test "split recovery preserves model state when its resize cannot be queued" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const plan = app.model.planPaneSplit(.{ .axis = .horizontal, .area = app.geometry().area }).?;
    while (app.model.to_runtime.hasCapacity()) {
        try app.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const before = app.model.version();
    const request_id: core.RequestId = @enumFromInt(4);
    try app.model.request_lifecycle.tracker.add(request_id, .{ .split = .{
        .target_pane = plan.split.target_pane,
        .location = plan.split.location,
        .axis = plan.split.axis,
        .area = plan.split.area,
    } });

    try std.testing.expectError(error.ClientOutboxFull, app.handleServerMessage(
        .{
            .request_failed = .{
                .request_id = request_id,
                .code = .internal,
                .message = "launch failed",
            },
        },
    ));
    try std.testing.expect(!app.model.request_lifecycle.tracker.has(.pane_operation));
    try std.testing.expectEqual(@as(u8, 0), app.model.notification_center.count);
    try std.testing.expectEqualDeep(before, app.model.version());
}

test "editor split retains its explicit target and arguments despite another focused pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const focused: core.PaneId = @enumFromInt(21);
    const panes = app.model.tabs.active;
    try data.pane_split.split(&app.model, panes, .{
        .existing_pane = TestHarness.bootstrap_pane,
        .new_pane = focused,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = app.geometry().area,
    });
    const before = app.model.version();
    const plan = (try app.requestPaneSplit(.{
        .axis = .vertical,
        .area = app.geometry().area,
        .target_pane = TestHarness.bootstrap_pane,
        .arguments = &.{ "nvim", "src/main.zig" },
    })).?;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, plan.split.target_pane);
    try std.testing.expectEqual(focused, app.model.tabs.layout[panes].focused().?);
    try std.testing.expectEqualDeep(before, app.model.version());
    try harness.settle();
    var buffer: [512]u8 = undefined;
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, resized.pane_resize.pane_id);
    const request = try harness.nextClientMessage(&buffer);
    try std.testing.expect(request == .create_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, request.create_pane.launch.cwd_source.?);
    var arguments = request.create_pane.launch.arguments();
    try std.testing.expectEqualStrings("nvim", (try arguments.next()).?);
    try std.testing.expectEqualStrings("src/main.zig", (try arguments.next()).?);
    try std.testing.expect(try arguments.next() == null);
}

test "routed pane focus reports applied or failed with the original correlation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const before = app.model.version();
    const pending = app.model.request_lifecycle.tracker.count;
    var command: core.ClientCommand = .{
        .request_id = @enumFromInt(91),
        .route = .{
            .id = 7,
            .generation = 9,
        },
        .action = .pane_focus,
        .target_id = @intFromEnum(TestHarness.bootstrap_pane),
    };
    var buffer: [core.ClientCommand.capacity]u8 = undefined;

    _ = try app.handleServerMessage(
        .{
            .client_command = command,
        },
    );
    try harness.settle();
    const applied = try harness.nextClientMessage(&buffer);
    try std.testing.expect(applied == .complete_client_command);
    try std.testing.expectEqual(command.request_id, applied.complete_client_command.request_id);
    try std.testing.expectEqualDeep(command.route, applied.complete_client_command.route);
    try std.testing.expectEqual(command.action, applied.complete_client_command.action);
    try std.testing.expectEqual(.applied, applied.complete_client_command.status);

    command.target_id = 0;
    _ = try app.handleServerMessage(
        .{
            .client_command = command,
        },
    );
    try harness.settle();
    const failed = try harness.nextClientMessage(&buffer);
    try std.testing.expect(failed == .complete_client_command);
    try std.testing.expectEqual(command.request_id, failed.complete_client_command.request_id);
    try std.testing.expectEqualDeep(command.route, failed.complete_client_command.route);
    try std.testing.expectEqual(command.action, failed.complete_client_command.action);
    try std.testing.expectEqual(.failed, failed.complete_client_command.status);
    try std.testing.expectEqualStrings("InvalidPaneId", failed.complete_client_command.text());
    try std.testing.expectEqualDeep(before, app.model.version());
    try std.testing.expectEqual(pending, app.model.request_lifecycle.tracker.count);
}

test "routed pane split acknowledges admission before runtime creation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    app.options.arguments = &.{
        "/bin/sh",
    };
    const before = app.model.version();
    var command: core.ClientCommand = .{
        .request_id = @enumFromInt(91),
        .route = .{
            .id = 7,
            .generation = 9,
        },
        .action = .pane_split,
        .target_id = @intFromEnum(TestHarness.bootstrap_pane),
    };
    try command.setText("vertical");
    _ = try app.handleServerMessage(
        .{
            .client_command = command,
        },
    );
    try std.testing.expectEqualDeep(before, app.model.version());
    try harness.settle();
    var buffer: [core.ClientCommand.capacity]u8 = undefined;
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, resized.pane_resize.pane_id);
    const created = try harness.nextClientMessage(&buffer);
    try std.testing.expect(created == .create_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.create_pane.launch.cwd_source.?);
    const continuation = app.model.request_lifecycle.tracker.take(created.create_pane.request_id).?;
    try std.testing.expect(continuation == .split);
    try std.testing.expectEqual(.vertical, continuation.split.axis);
    const reply = try harness.nextClientMessage(&buffer);
    try std.testing.expect(reply == .complete_client_command);
    try std.testing.expectEqual(command.request_id, reply.complete_client_command.request_id);
    try std.testing.expectEqualDeep(command.route, reply.complete_client_command.route);
    try std.testing.expectEqual(command.action, reply.complete_client_command.action);
    try std.testing.expectEqual(.admitted, reply.complete_client_command.status);
    try std.testing.expectEqualStrings("", reply.complete_client_command.text());
    try std.testing.expectEqualDeep(before, app.model.version());
}
