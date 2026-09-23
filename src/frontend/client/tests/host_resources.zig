//! Host facts committed by the shared client reach the terminal view when it
//! follows the model after an event.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");

test "host resources ignore repeated and invalid geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const app = harness.client;
    const version = app.model.version();

    try std.testing.expect(try app.applyHostUpdate(
        .{
            .size = app.model.host.host_size,
            .capabilities = app.model.host.host_capabilities,
        },
    ) == null);
    try std.testing.expectError(error.InvalidTerminalSize, app.applyHostUpdate(.{
        .size = .{ .cols = 80, .rows = 0 },
        .capabilities = app.model.host.host_capabilities,
    }));
    try std.testing.expectEqualDeep(version, app.model.version());
    try std.testing.expect(!app.model.to_host.invalidate_placements);
}

test "the view and the presenter follow committed grid and cell changes" {
    const sizes = [_]core.TerminalSize{
        .{ .cols = 100, .rows = 30 },
        .{ .cols = 80, .rows = 24, .cell_width_px = 10, .cell_height_px = 20 },
        .{ .cols = 100, .rows = 30, .cell_width_px = 10, .cell_height_px = 20 },
    };
    for (sizes) |size| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        const app = harness.client;
        const terminal = TerminalClient.of(app);
        var capabilities = app.model.host.host_capabilities;
        capabilities.cell_width_px = size.cell_width_px;
        capabilities.cell_height_px = size.cell_height_px;

        _ = try app.applyHostUpdate(
            .{
                .size = size,
                .capabilities = capabilities,
            },
        );
        try std.testing.expect(app.model.to_host.invalidate_placements);
        try harness.deliverHostEffects();

        try std.testing.expectEqual(size.cols, terminal.view.scratch.w);
        try std.testing.expectEqual(size.rows, terminal.view.scratch.h);
        try std.testing.expectEqual(size.cols, terminal.presenter.screen.back.w);
        try std.testing.expectEqual(size.rows, terminal.presenter.screen.back.h);
        try std.testing.expectEqual(size.cell_width_px, terminal.view.cell_width_px);
        try std.testing.expectEqual(size.cell_height_px, terminal.view.cell_height_px);
        try std.testing.expectEqual(terminal.view.workbench(), data.workbench.region(&app.model).area);
    }
}

test "the view follows image support once and ignores repeated observations" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const app = harness.client;

    _ = try app.observeHostCapability(
        .{
            .images = .supported,
        },
    );
    try std.testing.expect(app.model.to_host.invalidate_placements);
    try harness.deliverHostEffects();
    try std.testing.expectEqual(data.ResolvedSidebarRendering.kitty_hybrid, TerminalClient.of(app).view.sidebar_rendering);
    _ = try app.reconcileHostCapabilities(app.model.host.host_capabilities.withObservation(
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
    try std.testing.expect(try app.reconcileHostCapabilities(app.model.host.host_capabilities) == null);
    try std.testing.expectEqualDeep(version, app.model.version());
}

test "a sidebar renderer the host cannot draw fails the refresh and keeps the commit" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const app = harness.client;
    app.model.config.sidebar_rendering = .kitty_full;

    _ = try app.observeHostCapability(
        .{
            .images = .unsupported,
        },
    );

    try std.testing.expectError(error.KittyGraphicsUnsupported, harness.deliverHostEffects());
    try std.testing.expectEqual(data.environment.Support.unsupported, app.model.host.host_capabilities.images);
}
