//! Host facts committed by the shared client: repeated or invalid geometry
//! and capability observations change nothing, and a committed change asks
//! the adapter to place its graphics again.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const ClientHarness = @import("ClientHarness.zig");
const client_module = @import("telar-client");

test "host resources ignore repeated and invalid geometry" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const app = harness.client;
    const version = app.model.version();

    try std.testing.expect(try client_module.host_resize.applyHostUpdate(
        app,
        .{
            .size = app.model.host.host_size,
            .capabilities = app.model.host.host_capabilities,
        },
    ) == null);
    try std.testing.expectError(error.InvalidTerminalSize, client_module.host_resize.applyHostUpdate(app, .{
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
        var harness: ClientHarness = undefined;
        try harness.init();
        defer harness.deinit();
        const app = harness.client;
        var capabilities = app.model.host.host_capabilities;
        capabilities.cell_width_px = size.cell_width_px;
        capabilities.cell_height_px = size.cell_height_px;

        _ = try client_module.host_resize.applyHostUpdate(
            app,
            .{
                .size = size,
                .capabilities = capabilities,
            },
        );
        try std.testing.expect(app.model.to_host.invalidate_placements);
        try harness.deliverHostEffects();

        try std.testing.expectEqual(size.cols, app.model.host.host_size.cols);
        try std.testing.expectEqual(size.rows, app.model.host.host_size.rows);
        try std.testing.expectEqual(size.cell_width_px, app.model.host.host_capabilities.cell_width_px);
        try std.testing.expectEqual(size.cell_height_px, app.model.host.host_capabilities.cell_height_px);

        try harness.present();
        try std.testing.expectEqualDeep(app.model.version(), app.presentation.prepared.model);
        try std.testing.expectEqual(data.workbench.region(&app.model).revision, app.presentation.prepared.geometry_revision);
    }
}

test "the view follows image support once and ignores repeated observations" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const app = harness.client;

    _ = try client_module.host_capabilities.observeHostCapability(
        app,
        .{
            .images = .supported,
        },
    );
    try std.testing.expect(app.model.to_host.invalidate_placements);
    try harness.deliverHostEffects();
    try std.testing.expectEqual(data.environment.Support.supported, app.model.host.host_capabilities.images);
    _ = try client_module.host_capabilities.reconcileHostCapabilities(app, app.model.host.host_capabilities.withObservation(
        .{
            .pointer_pixels = .unsupported,
        },
    ));
    const version = app.model.version();

    try std.testing.expect(try client_module.host_capabilities.observeHostCapability(
        app,
        .{
            .images = .supported,
        },
    ) == null);
    try std.testing.expect(try client_module.host_capabilities.reconcileHostCapabilities(app, app.model.host.host_capabilities) == null);
    try std.testing.expectEqualDeep(version, app.model.version());
}
