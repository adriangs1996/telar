//! Vertical and application tests for client-owned pane viewports.

const std = @import("std");
const core = @import("telar-core");
const cell = @import("attachment/cell.zig");
const pane_viewport_commands = @import("commands/pane_viewport.zig");
const pane_viewport_controller = @import("controllers/pane_viewport.zig");
const test_support = @import("test_support.zig");

const schema = core.schema;
const PaneFixture = test_support.PaneFixture;
const ViewportController = pane_viewport_controller.Controller(*pane_viewport_commands.SetPaneViewportHandler);

fn fillScrollback(fixture: *PaneFixture) !void {
    _ = try fixture.pane.ingest(
        std.testing.io,
        "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n",
    );
    try fixture.pane.render(false);
}

fn attachmentOffset(fixture: *PaneFixture) !u32 {
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    const projection = try attachment.cells.project(fixture.pane, true);
    return projection.scroll.offset;
}

fn screenAtBottom(fixture: *PaneFixture) bool {
    const scrollbar = fixture.pane.terminal.screens.active.pages.scrollbar();
    return scrollbar.offset + scrollbar.len >= scrollbar.total;
}

test "viewport change crosses controller and handler and schedules one snapshot" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.cells.snapshot_pending = false;
    var handler: pane_viewport_commands.SetPaneViewportHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = ViewportController.init(&fixture.metrics, &handler);

    try controller.setPaneViewport(.{ .pane_id = fixture.pane.id, .offset = 0 });

    try std.testing.expectEqual(@as(u32, 0), try attachmentOffset(&fixture));
    try std.testing.expect(attachment.cells.viewport_pin != null);
    try std.testing.expect(attachment.cells.snapshot_pending);
    try std.testing.expect(screenAtBottom(&fixture));
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.stale_client_messages);
}

test "SetPaneViewportHandler leaves an identical historical viewport unchanged" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var handler: pane_viewport_commands.SetPaneViewportHandler = .{
        .attachments = &fixture.attachments,
    };
    const baseline_pin_count = fixture.pane.terminal.screens.active.pages.countTrackedPins();
    try std.testing.expectEqual(
        pane_viewport_commands.SetPaneViewportResult.changed,
        try handler.execute(.{ .pane_id = fixture.pane.id, .offset = 0 }),
    );
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    const original_pin = attachment.cells.viewport_pin.?;
    attachment.cells.snapshot_pending = false;

    const result = try handler.execute(.{ .pane_id = fixture.pane.id, .offset = 0 });

    try std.testing.expectEqual(pane_viewport_commands.SetPaneViewportResult.unchanged, result);
    try std.testing.expectEqual(original_pin, attachment.cells.viewport_pin.?);
    try std.testing.expect(!attachment.cells.snapshot_pending);
    try std.testing.expectEqual(baseline_pin_count + 1, fixture.pane.terminal.screens.active.pages.countTrackedPins());
    try std.testing.expect(screenAtBottom(&fixture));
}

test "SetPaneViewportHandler clamps beyond scrollback to bottom and releases its pin" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var handler: pane_viewport_commands.SetPaneViewportHandler = .{
        .attachments = &fixture.attachments,
    };
    const baseline_pin_count = fixture.pane.terminal.screens.active.pages.countTrackedPins();
    _ = try handler.execute(.{ .pane_id = fixture.pane.id, .offset = 0 });
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    attachment.cells.snapshot_pending = false;

    const changed = try handler.execute(.{
        .pane_id = fixture.pane.id,
        .offset = std.math.maxInt(u32),
    });

    try std.testing.expectEqual(pane_viewport_commands.SetPaneViewportResult.changed, changed);
    try std.testing.expect(attachment.cells.viewport_pin == null);
    try std.testing.expect(attachment.cells.snapshot_pending);
    try std.testing.expect(screenAtBottom(&fixture));
    try std.testing.expectEqual(baseline_pin_count, fixture.pane.terminal.screens.active.pages.countTrackedPins());

    attachment.cells.snapshot_pending = false;
    const unchanged = try handler.execute(.{
        .pane_id = fixture.pane.id,
        .offset = std.math.maxInt(u32),
    });
    try std.testing.expectEqual(pane_viewport_commands.SetPaneViewportResult.unchanged, unchanged);
    try std.testing.expect(!attachment.cells.snapshot_pending);
}

test "SetPaneViewportHandler leaves existing projection state unchanged for another pane" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var handler: pane_viewport_commands.SetPaneViewportHandler = .{
        .attachments = &fixture.attachments,
    };
    _ = try handler.execute(.{ .pane_id = fixture.pane.id, .offset = 0 });
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    const original_pin = attachment.cells.viewport_pin.?;
    attachment.cells.snapshot_pending = false;

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(99),
        .offset = 1,
    });

    try std.testing.expectEqual(pane_viewport_commands.SetPaneViewportResult.pane_not_attached, result);
    try std.testing.expectEqual(original_pin, attachment.cells.viewport_pin.?);
    try std.testing.expect(!attachment.cells.snapshot_pending);
    try std.testing.expectEqual(@as(u32, 0), try attachmentOffset(&fixture));
    try std.testing.expect(screenAtBottom(&fixture));
}

test "viewport pin allocation failure restores the shared screen and attachment state" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var held_syncs: [64]cell.Sync = undefined;
    var held_count: usize = 0;
    defer for (held_syncs[0..held_count]) |*sync| sync.deinit(fixture.pane);

    fixture.failNextPaneAllocation();
    var failure_observed = false;
    for (&held_syncs) |*sync| {
        sync.* = try cell.Sync.init(std.testing.allocator, fixture.pane);
        sync.snapshot_pending = false;

        const changed = sync.setViewport(fixture.pane, 0) catch |err| {
            if (err != error.OutOfMemory) {
                sync.deinit(fixture.pane);
                return err;
            }

            try std.testing.expect(sync.viewport_pin == null);
            try std.testing.expect(!sync.snapshot_pending);
            try std.testing.expect(screenAtBottom(&fixture));
            sync.deinit(fixture.pane);
            failure_observed = true;
            break;
        };

        try std.testing.expect(changed);
        held_count += 1;
    }

    try std.testing.expect(failure_observed);
    try std.testing.expect(fixture.pane_allocator.has_induced_failure);
    try std.testing.expect(screenAtBottom(&fixture));
}
