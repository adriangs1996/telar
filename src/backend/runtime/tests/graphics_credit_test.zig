//! Vertical and application tests for graphics transfer credit returns.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const delivery_mod = @import("../delivery/root.zig");
const graphics_credit_commands = @import("../application/commands/graphics_credit.zig");
const graphics_credit_controller = @import("../entrypoints/requests/graphics_credit.zig");
const system_metrics_mod = @import("../observability/root.zig").system_metrics;
const test_support = @import("support.zig");

const schema = core.schema;
const Delivery = delivery_mod.Delivery;
const PaneFixture = test_support.PaneFixture;
const GraphicsCreditController = graphics_credit_controller.Controller(*graphics_credit_commands.ReturnGraphicsCreditHandler);

test "ReturnGraphicsCreditHandler accepts the exact outstanding bound" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    const max_credit = core.graphics.max_image_bytes_per_pane;
    attachment.graphics.credit = 7;
    var handler: graphics_credit_commands.ReturnGraphicsCreditHandler = .{
        .attachments = &fixture.attachments,
    };

    const returned = try handler.execute(.{
        .pane_id = fixture.pane.id,
        .bytes = @intCast(max_credit - 7),
    });

    try std.testing.expectEqual(graphics_credit_commands.ReturnGraphicsCreditResult.returned, returned);
    try std.testing.expectEqual(max_credit, attachment.graphics.credit);

    for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |bytes| {
        const rejected = try handler.execute(.{
            .pane_id = fixture.pane.id,
            .bytes = bytes,
        });

        try std.testing.expectEqual(graphics_credit_commands.ReturnGraphicsCreditResult.invalid_amount, rejected);
        try std.testing.expectEqual(max_credit, attachment.graphics.credit);
    }
}

test "ReturnGraphicsCreditHandler leaves existing credit unchanged for another pane" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.graphics.credit = 13;
    var handler: graphics_credit_commands.ReturnGraphicsCreditHandler = .{
        .attachments = &fixture.attachments,
    };

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(99),
        .bytes = 1,
    });

    try std.testing.expectEqual(graphics_credit_commands.ReturnGraphicsCreditResult.pane_not_attached, result);
    try std.testing.expectEqual(@as(usize, 13), attachment.graphics.credit);
}

test "credit return crosses controller and handler with exact stale accounting" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    const max_credit = core.graphics.max_image_bytes_per_pane;
    attachment.graphics.credit = max_credit - 16;
    var handler: graphics_credit_commands.ReturnGraphicsCreditHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = GraphicsCreditController.init(&fixture.metrics, &handler);

    try controller.graphicsCredit(.{ .pane_id = fixture.pane.id, .bytes = 16 });

    try std.testing.expectEqual(max_credit, attachment.graphics.credit);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.stale_client_messages);

    try controller.graphicsCredit(.{ .pane_id = fixture.pane.id, .bytes = 1 });

    try std.testing.expectEqual(max_credit, attachment.graphics.credit);
    try std.testing.expectEqual(@as(u64, 1), fixture.metrics.stale_client_messages);
}

test "returned credit lets the next delivery pump stage a blocked image" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const media = fixture.pane.media_allocator.allocator();
    const pixels = try media.dupe(u8, &[_]u8{ 1, 2, 3, 255 });
    const screen = fixture.pane.media.terminal.screens.active;
    try screen.kitty_images.addImage(std.testing.io, media, screen, .{
        .id = 7,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = pixels },
    });
    fixture.pane.graphics_present = true;
    fixture.pane.graphics_revision = 1;

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.observed_cwd_revision = fixture.pane.cwd.revision;
    attachment.observed_foreground_revision = fixture.pane.foreground_revision;
    attachment.cells.snapshot_pending = false;
    attachment.cells.observed_revision = fixture.pane.cell_revision;
    attachment.graphics.snapshot = .idle;
    attachment.graphics.observed_revision = 0;
    attachment.graphics.credit = 3;
    fixture.pane.dirty = false;

    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    var panes: pane_mod.PaneStore = .{};
    var workspaces: workspace_mod.State = .{};
    var agents: agent_mod.Tracker = .{};
    var system_metrics: system_metrics_mod.Sampler = .{};
    const sources: delivery_mod.Sources = .{
        .panes = &panes,
        .workspaces = workspace_mod.Reader.init(&workspaces),
        .agents = &agents,
        .system_metrics = &system_metrics,
        .proxy_active = false,
        .home = null,
    };

    try std.testing.expect((try delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &fixture.attachments,
        .sources = sources,
        .metrics = &fixture.metrics,
    })) == null);
    try std.testing.expect(attachment.graphics.transfer == null);

    var handler: graphics_credit_commands.ReturnGraphicsCreditHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = GraphicsCreditController.init(&fixture.metrics, &handler);
    try controller.graphicsCredit(.{ .pane_id = fixture.pane.id, .bytes = 1 });

    const prepared = (try delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &fixture.attachments,
        .sources = sources,
        .metrics = &fixture.metrics,
    })).?;
    const message = try schema.decodeServer(prepared.payload);

    try std.testing.expect(message == .graphics_image);
    try std.testing.expectEqual(@as(usize, 0), attachment.graphics.credit);
    try std.testing.expect(attachment.graphics.transfer != null);

    delivery.commit(.{
        .prepared = prepared,
        .attachments = &fixture.attachments,
        .metrics = &fixture.metrics,
    });
    _ = delivery.complete({});
}
