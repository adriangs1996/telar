//! Vertical and application tests for the runtime pane-resize flow.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment/root.zig");
const pane_resize_commands = @import("../commands/pane_resize.zig");
const pane_resize_controller = @import("../controllers/pane_resize.zig");
const test_support = @import("support.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;
const Pane = @import("../../pane/root.zig").Pane;
const AttachmentStore = attachment_mod.AttachmentStore;
const PaneFixture = test_support.PaneFixture;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const ResizeController = pane_resize_controller.Controller(*pane_resize_commands.PaneResizeHandler);

const resized_size: schema.TerminalSize = .{ .cols = 30, .rows = 8, .cell_width_px = 9, .cell_height_px = 18 };

const Effect = enum { geometry_check, observation, media, geometry_release, response };

const Trace = struct {
    effects: [8]Effect = undefined,
    len: usize = 0,

    fn record(trace: *Trace, effect: Effect) void {
        std.debug.assert(trace.len < trace.effects.len);
        trace.effects[trace.len] = effect;
        trace.len += 1;
    }
};

const GeometryCapture = struct {
    trace: *Trace,
    attachments: *AttachmentStore,
    holds_result: bool = true,
    holds_calls: usize = 0,
    release_calls: usize = 0,
    checked_workspace: ?schema.WorkspaceLocation = null,
    released_workspace: ?schema.WorkspaceLocation = null,
    release_saw_empty_store: bool = false,
    release_saw_departed_workspace: bool = false,

    fn lease(capture: *GeometryCapture) pane_resize_commands.GeometryLease {
        return .{
            .context = capture,
            .holds = holds,
            .release = release,
        };
    }

    fn holds(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
        const capture: *GeometryCapture = @ptrCast(@alignCast(context));
        capture.trace.record(.geometry_check);
        capture.holds_calls += 1;
        capture.checked_workspace = workspace;
        return capture.holds_result;
    }

    fn release(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
        const capture: *GeometryCapture = @ptrCast(@alignCast(context));
        capture.trace.record(.geometry_release);
        capture.release_calls += 1;
        capture.released_workspace = workspace;
        capture.release_saw_empty_store = capture.attachments.len() == 0;
        capture.release_saw_departed_workspace = capture.attachments.currentWorkspace() == null;
    }
};

const SchedulerCapture = struct {
    trace: *Trace,
    attachments: *AttachmentStore,
    expected_size: schema.TerminalSize,
    observation_failure: ?anyerror = null,
    media_failure: ?anyerror = null,
    response_failure: ?anyerror = null,
    observation_saw_resized_pane: bool = false,
    observation_saw_old_attachment: bool = false,
    response_saw_resized_attachment: bool = false,

    fn scheduler(capture: *SchedulerCapture) pane_resize_commands.Scheduler {
        return .{
            .context = capture,
            .observation = scheduleObservation,
            .media = scheduleMedia,
            .response = scheduleResponse,
        };
    }

    fn scheduleObservation(context: *anyopaque, pane: *Pane) !void {
        const capture: *SchedulerCapture = @ptrCast(@alignCast(context));
        capture.trace.record(.observation);
        capture.observation_saw_resized_pane = std.meta.eql(pane.size, capture.expected_size);
        const attachment = capture.attachments.find(pane.id) orelse return error.MissingAttachment;
        capture.observation_saw_old_attachment = attachment.cells.acknowledged.w == PaneFixture.initial_size.cols and
            attachment.cells.acknowledged.h == PaneFixture.initial_size.rows;

        if (capture.observation_failure) |failure| {
            return failure;
        }
    }

    fn scheduleMedia(context: *anyopaque, _: *Pane) !void {
        const capture: *SchedulerCapture = @ptrCast(@alignCast(context));
        capture.trace.record(.media);

        if (capture.media_failure) |failure| {
            return failure;
        }
    }

    fn scheduleResponse(context: *anyopaque, pane: *Pane) !void {
        const capture: *SchedulerCapture = @ptrCast(@alignCast(context));
        capture.trace.record(.response);
        const attachment = capture.attachments.find(pane.id) orelse return error.MissingAttachment;
        capture.response_saw_resized_attachment = attachment.cells.acknowledged.w == capture.expected_size.cols and
            attachment.cells.acknowledged.h == capture.expected_size.rows;

        if (capture.response_failure) |failure| {
            return failure;
        }
    }
};

const ResizeHarness = struct {
    trace: Trace = .{},
    geometry: GeometryCapture = undefined,
    scheduler: SchedulerCapture = undefined,
    handler: pane_resize_commands.PaneResizeHandler = undefined,

    fn init(harness: *ResizeHarness, attachments: *AttachmentStore, expected_size: schema.TerminalSize) void {
        harness.trace = .{};
        harness.geometry = .{ .trace = &harness.trace, .attachments = attachments };
        harness.scheduler = .{
            .trace = &harness.trace,
            .attachments = attachments,
            .expected_size = expected_size,
        };
        harness.handler = .{
            .attachments = attachments,
            .geometry = harness.geometry.lease(),
            .scheduler = harness.scheduler.scheduler(),
        };
    }
};

fn expectEffects(trace: *const Trace, expected: []const Effect) !void {
    try std.testing.expectEqualSlices(Effect, expected, trace.effects[0..trace.len]);
}

test "PaneResizeHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var harness: ResizeHarness = undefined;
    harness.init(&attachments, resized_size);

    const result = try harness.handler.execute(.{
        .pane_id = try schema.id.pane(99),
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

    const second = try fixture.createPane(try schema.id.pane(8));
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
