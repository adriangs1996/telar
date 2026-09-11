//! Vertical and application tests for the runtime pane-resize flow.

const GenericPaneResizeController = @import("../entrypoints/requests/GenericPaneResizeController.zig").Type;
const PaneResizeHandlerType = @import("../application/commands/PaneResizeHandler.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const Trace = @import("Trace.zig");
const std = @import("std");
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const ResizeHarness = @import("ResizeHarness.zig");
const pane_module = @import("telar-core").pane;
const pane_resize_commands = @import("../application/commands/pane_resize.zig");
const PaneFixture = @import("PaneFixture.zig");

const ResizeController = GenericPaneResizeController(*PaneResizeHandlerType);

const resized_size: TerminalSizeType = .{ .cols = 30, .rows = 8, .cell_width_px = 9, .cell_height_px = 18 };

pub const Effect = enum { geometry_check, observation, media, geometry_release, response };

fn expectEffects(trace: *const Trace, expected: []const Effect) !void {
    try std.testing.expectEqualSlices(Effect, expected, trace.effects[0..trace.len]);
}

test "PaneResizeHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var harness: ResizeHarness = undefined;
    harness.init(&attachments, resized_size);

    const result = try harness.handler.execute(.{
        .pane_id = try pane_module(99),
        .size = resized_size,
    });

    try std.testing.expectEqual(pane_resize_commands.PaneResizeResult.pane_not_attached, result);
    try expectEffects(&harness.trace, &.{});
    try std.testing.expectEqual(@as(usize, 0), harness.geometry.holds_calls);
}

test "PaneResizeHandler rejects a client without the workspace geometry lease" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);
    harness.geometry.holds_result = false;

    const result = try harness.handler.execute(.{ .pane_id = fixture.pane.id, .size = resized_size });

    try std.testing.expectEqual(pane_resize_commands.PaneResizeResult.geometry_rejected, result);
    try expectEffects(&harness.trace, &.{.geometry_check});
    try std.testing.expectEqualDeep(fixture.pane.location.workspace, harness.geometry.checked_workspace.?);
    try std.testing.expectEqualDeep(PaneFixture.initial_size, fixture.pane.size);
    try std.testing.expect(fixture.pane.pending_size == null);
}

test "PaneResizeHandler defers terminal and attachment mutation during ingest" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    fixture.pane.ingest_pending = true;
    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);

    const result = try harness.handler.execute(.{ .pane_id = fixture.pane.id, .size = resized_size });

    try std.testing.expectEqual(pane_resize_commands.PaneResizeResult.handled, result);
    try expectEffects(&harness.trace, &.{.geometry_check});
    try std.testing.expectEqualDeep(PaneFixture.initial_size, fixture.pane.size);
    try std.testing.expectEqualDeep(resized_size, fixture.pane.pending_size.?);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(PaneFixture.initial_size.cols, attachment.cells.acknowledged.w);
    try std.testing.expectEqual(PaneFixture.initial_size.rows, attachment.cells.acknowledged.h);
}

test "pane resize crosses controller and handler in synchronization order" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);
    var controller = ResizeController.init(&fixture.metrics, &harness.handler);

    try controller.paneResize(.{ .pane_id = fixture.pane.id, .size = resized_size });

    try expectEffects(&harness.trace, &.{ .geometry_check, .observation, .media, .response });
    try std.testing.expect(harness.scheduler.observation_saw_resized_pane);
    try std.testing.expect(harness.scheduler.observation_saw_old_attachment);
    try std.testing.expect(harness.scheduler.response_saw_resized_attachment);
    try std.testing.expectEqualDeep(resized_size, fixture.pane.size);
    try std.testing.expect(fixture.pane.pending_size == null);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.geometry_rejections);
}

test "PaneResizeHandler keeps an equal resize allocation-free but refreshes dependents" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    fixture.failNextPaneAllocation();
    fixture.failNextAttachmentAllocation();
    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, PaneFixture.initial_size);

    const result = try harness.handler.execute(.{
        .pane_id = fixture.pane.id,
        .size = PaneFixture.initial_size,
    });

    try std.testing.expectEqual(pane_resize_commands.PaneResizeResult.handled, result);
    try expectEffects(&harness.trace, &.{ .geometry_check, .observation, .media, .response });
    try std.testing.expect(fixture.attachments.find(fixture.pane.id) != null);
    try std.testing.expect(!fixture.pane.close_requested);
}

test "PaneResizeHandler propagates PTY resize failure before local mutation" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    fixture.pane.session.deinit();
    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);

    try std.testing.expectError(error.SetWindowSizeFailed, harness.handler.execute(.{
        .pane_id = fixture.pane.id,
        .size = resized_size,
    }));

    try expectEffects(&harness.trace, &.{.geometry_check});
    try std.testing.expectEqualDeep(PaneFixture.initial_size, fixture.pane.size);
    try std.testing.expect(fixture.pane.pending_size == null);
}

test "PaneResizeHandler closes the pane when its local resize cannot commit" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    fixture.failNextPaneAllocation();
    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);

    const result = try harness.handler.execute(.{ .pane_id = fixture.pane.id, .size = resized_size });

    try std.testing.expectEqual(pane_resize_commands.PaneResizeResult.handled, result);
    try expectEffects(&harness.trace, &.{.geometry_check});
    try std.testing.expect(fixture.pane.close_requested);
    try std.testing.expectEqualDeep(PaneFixture.initial_size, fixture.pane.size);
    try std.testing.expectEqualDeep(resized_size, fixture.pane.pending_size.?);
}

test "PaneResizeHandler stops before attachment sync on observation failure" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);
    harness.scheduler.observation_failure = error.ObserverUnavailable;

    try std.testing.expectError(error.ObserverUnavailable, harness.handler.execute(.{
        .pane_id = fixture.pane.id,
        .size = resized_size,
    }));

    try expectEffects(&harness.trace, &.{ .geometry_check, .observation });
    try std.testing.expectEqualDeep(resized_size, fixture.pane.size);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(PaneFixture.initial_size.cols, attachment.cells.acknowledged.w);
}

test "PaneResizeHandler stops before attachment sync on media failure" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);
    harness.scheduler.media_failure = error.MediaUnavailable;

    try std.testing.expectError(error.MediaUnavailable, harness.handler.execute(.{
        .pane_id = fixture.pane.id,
        .size = resized_size,
    }));

    try expectEffects(&harness.trace, &.{ .geometry_check, .observation, .media });
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    try std.testing.expectEqual(PaneFixture.initial_size.cols, attachment.cells.acknowledged.w);
}

test "PaneResizeHandler detaches the last projection after attachment allocation failure" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    fixture.failNextAttachmentAllocation();
    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);

    const result = try harness.handler.execute(.{ .pane_id = fixture.pane.id, .size = resized_size });

    try std.testing.expectEqual(pane_resize_commands.PaneResizeResult.handled, result);
    try expectEffects(&harness.trace, &.{ .geometry_check, .observation, .media, .geometry_release });
    try std.testing.expectEqual(@as(usize, 1), harness.geometry.release_calls);
    try std.testing.expectEqualDeep(fixture.pane.location.workspace, harness.geometry.released_workspace.?);
    try std.testing.expect(harness.geometry.release_saw_empty_store);
    try std.testing.expect(harness.geometry.release_saw_departed_workspace);
    try std.testing.expect(fixture.attachments.find(fixture.pane.id) == null);
}

test "PaneResizeHandler retains workspace geometry when another attachment survives" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const second = try fixture.createPane(try pane_module(8));
    _ = try fixture.attachments.attach(fixture.attachment_allocator.allocator(), second);
    defer {
        _ = fixture.attachments.detach(second.id);
        second.session.shutdown();
        second.destroy();
    }

    fixture.failNextAttachmentAllocation();
    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);

    const result = try harness.handler.execute(.{ .pane_id = fixture.pane.id, .size = resized_size });

    try std.testing.expectEqual(pane_resize_commands.PaneResizeResult.handled, result);
    try expectEffects(&harness.trace, &.{ .geometry_check, .observation, .media });
    try std.testing.expectEqual(@as(usize, 0), harness.geometry.release_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.attachments.len());
    try std.testing.expect(fixture.attachments.find(second.id) != null);
    try std.testing.expect(fixture.attachments.currentWorkspace() != null);
}

test "PaneResizeHandler preserves synchronized state when response scheduling fails" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var harness: ResizeHarness = undefined;
    harness.init(&fixture.attachments, resized_size);
    harness.scheduler.response_failure = error.ResponseUnavailable;

    try std.testing.expectError(error.ResponseUnavailable, harness.handler.execute(.{
        .pane_id = fixture.pane.id,
        .size = resized_size,
    }));

    try expectEffects(&harness.trace, &.{ .geometry_check, .observation, .media, .response });
    try std.testing.expect(harness.scheduler.response_saw_resized_attachment);
    try std.testing.expectEqualDeep(resized_size, fixture.pane.size);
    try std.testing.expect(fixture.attachments.find(fixture.pane.id) != null);
}
