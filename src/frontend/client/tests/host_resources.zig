//! Exercises host policy through the client and actual host port boundary.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const TestHarness = @import("TestHarness.zig");
const Probe = @import("HostResourceProbe.zig");

test "host resources suppress repeated and invalid geometry before ports" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const app = harness.client;
    const version = app.model.version();
    var probe = Probe.init(app);
    probe.bind();
    defer probe.restore();

    try std.testing.expect(try app.applyHostUpdate(
        .{
            .size = app.model.hostSize(),
            .capabilities = app.model.hostCapabilities(),
        },
    ) == null);
    try std.testing.expectError(error.InvalidTerminalSize, app.applyHostUpdate(.{
        .size = .{ .cols = 80, .rows = 0 },
        .capabilities = app.model.hostCapabilities(),
    }));
    try std.testing.expectEqualDeep(version, app.model.version());
    try std.testing.expectEqual(@as(usize, 0), probe.len);
}

test "host resources select grid and cell changes independently in order" {
    const sizes = [_]core.TerminalSize{
        .{ .cols = 100, .rows = 30 },
        .{ .cols = 80, .rows = 24, .cell_width_px = 10, .cell_height_px = 20 },
        .{ .cols = 100, .rows = 30, .cell_width_px = 10, .cell_height_px = 20 },
    };
    const expected = [_][]const Probe.Event{
        &.{ .presenter, .view, .invalidate },
        &.{ .sidebar, .invalidate },
        &.{ .presenter, .view, .sidebar, .invalidate },
    };
    for (sizes, expected) |size, events| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        const app = harness.client;
        var probe = Probe.init(app);
        probe.expected_size = size;
        probe.bind();
        defer probe.restore();
        var capabilities = app.model.hostCapabilities();
        capabilities.cell_width_px = size.cell_width_px;
        capabilities.cell_height_px = size.cell_height_px;

        _ = try app.applyHostUpdate(
            .{
                .size = size,
                .capabilities = capabilities,
            },
        );

        try std.testing.expectEqualSlices(Probe.Event, events, probe.slice());
        try std.testing.expect(probe.committed);
        if (size.cell_width_px != 0) {
            try std.testing.expectEqualDeep(client.SidebarRendererInput{
                .support = capabilities.images,
                .cell_width = size.cell_width_px,
                .cell_height = size.cell_height_px,
            }, probe.sidebar.?);
        }
    }
}

test "host resources stop at each failed resize port and retain the commit" {
    const failures = [_]Probe.Event{ .presenter, .view, .sidebar };
    const expected = [_][]const Probe.Event{
        &.{.presenter},
        &.{ .presenter, .view },
        &.{ .presenter, .view, .sidebar },
    };
    for (failures, expected) |failure, events| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        const app = harness.client;
        const size: core.TerminalSize = .{ .cols = 100, .rows = 30, .cell_width_px = 10, .cell_height_px = 20 };
        var probe = Probe.init(app);
        probe.failure = failure;
        probe.expected_size = size;
        probe.bind();
        defer probe.restore();
        var capabilities = app.model.hostCapabilities();
        capabilities.cell_width_px = size.cell_width_px;
        capabilities.cell_height_px = size.cell_height_px;

        try std.testing.expectError(error.HostResourceFailed, app.applyHostUpdate(
            .{
                .size = size,
                .capabilities = capabilities,
            },
        ));
        try std.testing.expectEqualSlices(Probe.Event, events, probe.slice());
        try std.testing.expect(probe.committed);
        try std.testing.expectEqualDeep(size, app.model.hostSize());
        try std.testing.expectEqualDeep(capabilities, app.model.hostCapabilities());
    }
}

test "host resources configure graphics before invalidating and suppress repeated observations" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const app = harness.client;
    var probe = Probe.init(app);
    probe.bind();
    defer probe.restore();

    _ = try app.observeHostCapability(
        .{
            .images = .supported,
        },
    );
    try std.testing.expectEqualSlices(Probe.Event, &.{ .sidebar, .invalidate }, probe.slice());
    try std.testing.expect(probe.committed);
    _ = try app.reconcileHostCapabilities(app.model.hostCapabilities().withObservation(
        .{
            .pointer_pixels = .unsupported,
        },
    ));
    const version = app.model.version();

    try std.testing.expect(try app.observeHostCapability(
        .{
            .images = .supported,
        },
    ) == null);
    try std.testing.expect(try app.reconcileHostCapabilities(app.model.hostCapabilities()) == null);
    try std.testing.expectEqualDeep(version, app.model.version());
    try std.testing.expectEqual(@as(usize, 2), probe.len);
}

test "host resources retain graphics capabilities when sidebar setup fails" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const app = harness.client;
    var probe = Probe.init(app);
    probe.failure = .sidebar;
    probe.bind();
    defer probe.restore();

    try std.testing.expectError(error.HostResourceFailed, app.observeHostCapability(
        .{
            .images = .supported,
        },
    ));
    try std.testing.expectEqualSlices(Probe.Event, &.{.sidebar}, probe.slice());
    try std.testing.expect(probe.committed);
    try std.testing.expectEqual(client.Support.supported, app.model.hostCapabilities().images);
}
