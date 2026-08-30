//! Vertical tests for bounded terminal selection and clipboard delivery.

const std = @import("std");
const copy_selection_commands = @import("commands/copy_selection.zig");
const copy_selection_controller = @import("controllers/copy_selection.zig");
const delivery_mod = @import("delivery.zig");
const test_support = @import("test_support.zig");

const Delivery = delivery_mod.Delivery;
const PaneFixture = test_support.PaneFixture;
const CopySelectionController = copy_selection_controller.Controller(*copy_selection_commands.CopySelectionHandler, *Delivery);

fn fillScrollback(fixture: *PaneFixture) !void {
    _ = try fixture.pane.ingest(
        std.testing.io,
        "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive",
    );
    try fixture.pane.render(false);
}

fn copiedBytes(result: copy_selection_commands.CopySelectionResult) ![]const u8 {
    return switch (result) {
        .copied => |bytes| bytes,
        .pane_not_attached => error.PaneNotAttached,
        .unavailable => error.SelectionUnavailable,
        .too_large => error.SelectionTooLarge,
    };
}

test "CopySelectionHandler reads inclusive absolute scrollback coordinates" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var handler: copy_selection_commands.CopySelectionHandler = .{
        .attachments = &fixture.attachments,
    };
    var scratch: [copy_selection_commands.scratch_bytes]u8 = undefined;
    const result = handler.execute(.{
        .pane_id = fixture.pane.id,
        .start_x = 1,
        .start_y = 1,
        .end_x = 2,
        .end_y = 2,
        .linewise = false,
    }, &scratch);

    try std.testing.expectEqualStrings("ne\ntwo", try copiedBytes(result));
}

test "CopySelectionHandler preserves reverse linear selection semantics" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var handler: copy_selection_commands.CopySelectionHandler = .{
        .attachments = &fixture.attachments,
    };
    var scratch: [copy_selection_commands.scratch_bytes]u8 = undefined;
    const result = handler.execute(.{
        .pane_id = fixture.pane.id,
        .start_x = 2,
        .start_y = 2,
        .end_x = 1,
        .end_y = 1,
        .linewise = false,
    }, &scratch);

    try std.testing.expectEqualStrings("ne\ntwo", try copiedBytes(result));
}

test "CopySelectionHandler normalizes linewise selection and clamps columns" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var handler: copy_selection_commands.CopySelectionHandler = .{
        .attachments = &fixture.attachments,
    };
    var scratch: [copy_selection_commands.scratch_bytes]u8 = undefined;
    const linewise = handler.execute(.{
        .pane_id = fixture.pane.id,
        .start_x = 19,
        .start_y = 2,
        .end_x = 19,
        .end_y = 1,
        .linewise = true,
    }, &scratch);

    try std.testing.expectEqualStrings("one\ntwo", try copiedBytes(linewise));

    const clamped = handler.execute(.{
        .pane_id = fixture.pane.id,
        .start_x = 0,
        .start_y = 1,
        .end_x = std.math.maxInt(u16),
        .end_y = 1,
        .linewise = false,
    }, &scratch);

    try std.testing.expectEqualStrings("one", try copiedBytes(clamped));

    const beyond_history = handler.execute(.{
        .pane_id = fixture.pane.id,
        .start_x = 0,
        .start_y = std.math.maxInt(u32),
        .end_x = 0,
        .end_y = std.math.maxInt(u32),
        .linewise = false,
    }, &scratch);

    try std.testing.expectEqualStrings("", try copiedBytes(beyond_history));
}

test "CopySelectionHandler reports bounded scratch exhaustion" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var handler: copy_selection_commands.CopySelectionHandler = .{
        .attachments = &fixture.attachments,
    };
    var scratch: [1]u8 = undefined;
    const result = handler.execute(.{
        .pane_id = fixture.pane.id,
        .start_x = 0,
        .start_y = 1,
        .end_x = 2,
        .end_y = 1,
        .linewise = false,
    }, &scratch);

    try std.testing.expectEqual(std.meta.Tag(copy_selection_commands.CopySelectionResult).too_large, std.meta.activeTag(result));
}

test "copy selection crosses controller and handler before replacing clipboard delivery" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fillScrollback(&fixture);

    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    try std.testing.expect(delivery.setClipboard(fixture.pane.id, "previous"));
    var handler: copy_selection_commands.CopySelectionHandler = .{
        .attachments = &fixture.attachments,
    };
    var controller = CopySelectionController.init(&fixture.metrics, &handler, &delivery);

    controller.copySelection(.{
        .pane_id = fixture.pane.id,
        .start_x = 0,
        .start_y = 1,
        .end_x = 2,
        .end_y = 1,
        .linewise = false,
    });

    try std.testing.expect(delivery.clipboard_pending);
    try std.testing.expectEqual(fixture.pane.id, delivery.clipboard_pane);
    try std.testing.expectEqualStrings("one", delivery.clipboard_storage[0..delivery.clipboard_len]);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.stale_client_messages);
}
