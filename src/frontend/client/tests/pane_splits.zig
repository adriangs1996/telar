//! Split behavior through the concrete client, its model and real transport.
const std = @import("std");
const core = @import("telar-core");
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
    const queued = app.runtime_transport.outbox.len;
    const next_id = app.request_lifecycle.next_request_id;

    try std.testing.expect(try app.requestPaneSplit(
        .{
            .axis = .vertical,
            .area = app.geometry().area,
        },
    ) == null);
    try std.testing.expectEqual(queued, app.runtime_transport.outbox.len);
    try std.testing.expectEqual(next_id, app.request_lifecycle.next_request_id);
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
    app.request_lifecycle.next_request_id = std.math.maxInt(u64);

    try std.testing.expectError(error.RequestIdExhausted, app.requestPaneSplit(
        .{
            .axis = .horizontal,
            .area = app.geometry().area,
        },
    ));
    try std.testing.expect(!app.request_lifecycle.tracker.has(.pane_operation));
    try std.testing.expectEqualDeep(before, app.model.version());
    try harness.settle();
    var buffer: [512]u8 = undefined;
    const provisional = try harness.nextClientMessage(&buffer);
    try std.testing.expect(provisional == .pane_resize);
    try std.testing.expectEqualDeep(plan.provisional_resize, provisional.pane_resize);
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
        try app.request_lifecycle.tracker.add(opened.request_id, .{ .split = .{
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
        try std.testing.expect(!app.request_lifecycle.tracker.has(.pane_operation));
        try std.testing.expectEqualDeep(before, app.model.version());
        try std.testing.expectEqual(@as(usize, 0), app.runtime_transport.outbox.len);
    }
}

test "split retains the runtime creation when confirmation delivery fails" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const plan = app.model.planPaneSplit(.{ .axis = .horizontal, .area = app.geometry().area }).?;
    while (app.runtime_transport.outbox.hasCapacity()) {
        try app.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const before = app.model.version();
    const pane: core.PaneId = @enumFromInt(21);

    const request_id: core.RequestId = @enumFromInt(4);
    try app.request_lifecycle.tracker.add(
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
    try std.testing.expect(app.model.workspace.findPane(pane).?.attached);
    try std.testing.expectEqual(pane, app.model.workspace.active().?.model.layout.focused().?);
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
    try std.testing.expect(app.model.workspace.remove(plan.split.location.tab_id));
    const before = app.model.version();

    const request_id: core.RequestId = @enumFromInt(4);
    try app.request_lifecycle.tracker.add(
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
    try std.testing.expect(app.model.workspace.findPane(current).?.attached);
    try std.testing.expectEqualDeep(before, app.model.version());
    try std.testing.expectEqual(@as(usize, 0), app.runtime_transport.outbox.len);
}

test "split recovery preserves model state when its resize cannot be queued" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const plan = app.model.planPaneSplit(.{ .axis = .horizontal, .area = app.geometry().area }).?;
    while (app.runtime_transport.outbox.hasCapacity()) {
        try app.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const before = app.model.version();
    const request_id: core.RequestId = @enumFromInt(4);
    try app.request_lifecycle.tracker.add(request_id, .{ .split = .{
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
    try std.testing.expect(!app.request_lifecycle.tracker.has(.pane_operation));
    try std.testing.expectEqual(@as(u8, 0), app.model.notificationSnapshot().count);
    try std.testing.expectEqualDeep(before, app.model.version());
}

test "editor split retains its explicit target and arguments despite another focused pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const app = harness.client;
    const focused: core.PaneId = @enumFromInt(21);
    const panes = app.model.activeTabModel().?;
    try panes.split(.{
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
    try std.testing.expectEqual(focused, panes.layout.focused().?);
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
