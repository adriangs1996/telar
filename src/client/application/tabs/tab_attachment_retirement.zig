//! Application policy for retiring one tab's client-owned runtime
//! attachments without changing semantic presentation state.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const pane_paste = @import("../input/root.zig").pane_paste;

pub const schema = core.schema;

pub const PendingAttachments = @import("PendingAttachments.zig");

pub const Effects = @import("TabAttachmentRetirementEffects.zig");

/// Counts the exact outbound deliveries required by a captured tab retirement
/// without changing model or request state.
///
/// ```zig
/// const required = requiredDeliveryCapacity(&plan, pending_attachments);
/// ```
pub fn requiredDeliveryCapacity(plan: *const client_model.TabDetachmentPlan, pending_attachments: PendingAttachments) usize {
    var required = @as(usize, @intFromBool(plan.paste_marker_required));
    required += @intFromBool(plan.focus_out_required);

    for (plan.slice()) |pane| {
        const pending = pending_attachments.pending(pending_attachments.context, pane.pane_id);
        required += @intFromBool(pane.attached or pending);
    }

    return required;
}

pub const RetireTabAttachmentsHandler = @import("RetireTabAttachmentsHandler.zig");

pub const Event = union(enum) {
    paste,
    focus,
    pending: schema.PaneId,
    detach: schema.PaneId,
    retire: schema.PaneId,
    hide: schema.PaneId,
};

pub const Failure = enum {
    none,
    paste,
    focus,
    second_detach,
    second_hide,
};

const TestingModel = @import("TabAttachmentRetirementTestingModel.zig");

const Capture = @import("TabAttachmentRetirementCapture.zig");

fn testingHandler(testing: *TestingModel, capture: *Capture) RetireTabAttachmentsHandler {
    return .{
        .model = testing.model,
        .paste_effects = capture.pasteEffects(),
        .focus_effects = capture.focusEffects(),
        .effects = capture.attachmentEffects(),
    };
}

test "tab retirement capacity counts only required deliveries" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .root = testing.root,
        .sibling = testing.sibling,
        .pending_pane = testing.sibling,
    };
    const plan = try testing.model.planTabDetachment(testing.target);

    const required = requiredDeliveryCapacity(&plan, capture.pendingAttachments());

    try std.testing.expectEqual(@as(usize, 4), required);
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .pending = testing.root },
        .{ .pending = testing.sibling },
    }, capture.eventSlice());
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
}

test "RetireTabAttachmentsHandler orders authorities and panes before commit" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .root = testing.root,
        .sibling = testing.sibling,
        .pending_pane = testing.sibling,
        .paste_available = false,
    };
    var use_case = testingHandler(&testing, &capture);

    try use_case.execute(testing.target);

    try std.testing.expectEqualDeep(&[_]Event{
        .paste,
        .focus,
        .{ .pending = testing.root },
        .{ .detach = testing.root },
        .{ .retire = testing.root },
        .{ .hide = testing.root },
        .{ .pending = testing.sibling },
        .{ .detach = testing.sibling },
        .{ .retire = testing.sibling },
        .{ .hide = testing.sibling },
    }, capture.eventSlice());
    try std.testing.expect(capture.paste_observed_active);
    try std.testing.expect(capture.focus_observed_committed);
    try std.testing.expect(capture.pane_effects_observed_released);
    try std.testing.expect(capture.commit_deferred);
    try std.testing.expect(!testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expectEqual(@as(u64, 0), testing.model.workspace.findPane(testing.root).?.pending_frame_id);
    try std.testing.expectEqual(@as(u64, 0), testing.model.workspace.findPane(testing.sibling).?.pending_frame_id);
    try std.testing.expect(testing.model.workspace.findPane(testing.active_pane).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RetireTabAttachmentsHandler preserves unrelated authorities and skips detached panes" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const target_session = testing.model.panePasteSession().?;
    try std.testing.expect(testing.model.finishPanePaste(target_session));
    _ = testing.model.clearReportedPaneFocus().?;
    const active_pane = testing.model.workspace.findPane(testing.active_pane).?;
    active_pane.input_modes.bracketed_paste = true;
    active_pane.input_modes.focus_events = true;
    _ = testing.model.beginPanePaste().?;
    _ = testing.model.syncReportedPaneFocus().?;
    testing.model.workspace.findPane(testing.root).?.attached = false;
    var capture: Capture = .{
        .model = testing.model,
        .root = testing.root,
        .sibling = testing.sibling,
        .pending_pane = null,
    };
    var use_case = testingHandler(&testing, &capture);

    try use_case.execute(testing.target);
    try use_case.execute(testing.target);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .pending = testing.root },
        .{ .pending = testing.sibling },
        .{ .pending = testing.root },
        .{ .pending = testing.sibling },
    }, capture.eventSlice());
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expectEqual(testing.active_pane, testing.model.reportedPaneFocus().?.pane_id);
}

test "RetireTabAttachmentsHandler rejects a missing exact tab before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .root = testing.root,
        .sibling = testing.sibling,
        .pending_pane = testing.sibling,
    };
    var use_case = testingHandler(&testing, &capture);

    try std.testing.expectError(error.UnexpectedTab, use_case.execute(.{
        .workspace = testing.target.workspace,
        .tab_id = @enumFromInt(9),
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
}

test "RetireTabAttachmentsHandler preserves partial effects and defers attachment commit on failure" {
    const Scenario = struct {
        failure: Failure,
        expected_error: anyerror,
        expected_events: []const Event,
        paste_retired: bool,
        focus_retired: bool,
    };
    const root: schema.PaneId = @enumFromInt(1);
    const sibling: schema.PaneId = @enumFromInt(2);
    const scenarios = [_]Scenario{
        .{
            .failure = .paste,
            .expected_error = error.PasteFailure,
            .expected_events = &.{.paste},
            .paste_retired = true,
            .focus_retired = false,
        },
        .{
            .failure = .focus,
            .expected_error = error.FocusFailure,
            .expected_events = &.{ .paste, .focus },
            .paste_retired = true,
            .focus_retired = true,
        },
        .{
            .failure = .second_detach,
            .expected_error = error.DetachFailure,
            .expected_events = &.{
                .paste,
                .focus,
                .{ .pending = root },
                .{ .detach = root },
                .{ .retire = root },
                .{ .hide = root },
                .{ .pending = sibling },
                .{ .detach = sibling },
            },
            .paste_retired = true,
            .focus_retired = true,
        },
        .{
            .failure = .second_hide,
            .expected_error = error.HideFailure,
            .expected_events = &.{
                .paste,
                .focus,
                .{ .pending = root },
                .{ .detach = root },
                .{ .retire = root },
                .{ .hide = root },
                .{ .pending = sibling },
                .{ .detach = sibling },
                .{ .retire = sibling },
                .{ .hide = sibling },
            },
            .paste_retired = true,
            .focus_retired = true,
        },
    };

    for (scenarios) |scenario| {
        var testing = try TestingModel.init();
        defer testing.deinit();
        var capture: Capture = .{
            .model = testing.model,
            .root = testing.root,
            .sibling = testing.sibling,
            .pending_pane = testing.sibling,
            .failure = scenario.failure,
        };
        var use_case = testingHandler(&testing, &capture);

        try std.testing.expectError(scenario.expected_error, use_case.execute(testing.target));

        try std.testing.expectEqualDeep(scenario.expected_events, capture.eventSlice());
        try std.testing.expectEqual(scenario.paste_retired, !testing.model.panePasteActive());
        try std.testing.expectEqual(scenario.focus_retired, testing.model.reportedPaneFocus() == null);
        try std.testing.expect(capture.commit_deferred);
        try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
        try std.testing.expectEqual(@as(u64, 7), testing.model.workspace.findPane(testing.root).?.pending_frame_id);
        try std.testing.expectEqual(@as(u64, 9), testing.model.workspace.findPane(testing.sibling).?.pending_frame_id);
    }
}
