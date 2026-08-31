//! Application policy for retiring one tab's client-owned runtime
//! attachments without changing semantic presentation state.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");
const pane_focus_reporting = @import("pane_focus_reporting.zig");
const pane_paste = @import("pane_paste.zig");

const schema = core.schema;

pub const Effects = struct {
    context: *anyopaque,
    attachment_pending: *const fn (*anyopaque, schema.PaneId) bool,
    detach_pane: *const fn (*anyopaque, schema.PaneId) anyerror!void,
    retire_attachment: *const fn (*anyopaque, schema.PaneId) void,
    hide_graphics: *const fn (*anyopaque, schema.PaneId) anyerror!void,
};

pub const RetireTabAttachmentsHandler = struct {
    model: *client_model.Model,
    paste_effects: pane_paste.Effects,
    focus_effects: pane_focus_reporting.Effects,
    effects: Effects,

    /// Finishes tab-owned input authorities, delivers every required detach
    /// in pane order and commits operational detachment only after all effects.
    ///
    /// ```zig
    /// try handler.execute(location);
    /// ```
    pub fn execute(handler: *RetireTabAttachmentsHandler, location: schema.TabLocation) !void {
        const plan = try handler.model.planTabDetachment(location);

        if (plan.owns_paste) {
            var paste_handler: pane_paste.PanePasteHandler = .{
                .model = handler.model,
                .effects = handler.paste_effects,
            };
            const outcome = try paste_handler.finish();
            std.debug.assert(outcome != .ignored);
        }

        if (plan.owns_reported_focus) {
            var focus_handler: pane_focus_reporting.PaneFocusReportingHandler = .{
                .model = handler.model,
                .effects = handler.focus_effects,
            };
            const outcome = try focus_handler.execute(.clear);
            std.debug.assert(outcome == .applied);
        }

        for (plan.slice()) |pane| {
            const pending = handler.effects.attachment_pending(handler.effects.context, pane.pane_id);
            if (!pane.attached and !pending) {
                continue;
            }

            try handler.effects.detach_pane(handler.effects.context, pane.pane_id);
            handler.effects.retire_attachment(handler.effects.context, pane.pane_id);
            try handler.effects.hide_graphics(handler.effects.context, pane.pane_id);
        }

        try handler.model.commitTabDetachment(plan);
    }
};

const Event = union(enum) {
    paste,
    focus,
    pending: schema.PaneId,
    detach: schema.PaneId,
    retire: schema.PaneId,
    hide: schema.PaneId,
};

const Failure = enum {
    none,
    paste,
    focus,
    second_detach,
    second_hide,
};

const TestingModel = struct {
    model: *client_model.Model,
    target: schema.TabLocation,
    active: schema.TabLocation,
    root: schema.PaneId,
    sibling: schema.PaneId,
    active_pane: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const target: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
        const active: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
        const root: schema.PaneId = @enumFromInt(1);
        const sibling: schema.PaneId = @enumFromInt(2);
        const active_pane: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(root, target, .{ .cols = 20, .rows = 5 });
        try model.workspace.active().?.model.split(root, sibling, target, .horizontal, .{ .w = 40, .h = 10 });
        try std.testing.expect(model.workspace.active().?.model.focusPane(root));
        const root_pane = model.workspace.findPane(root).?;
        const sibling_pane = model.workspace.findPane(sibling).?;
        root_pane.input_modes.bracketed_paste = true;
        root_pane.input_modes.focus_events = true;
        root_pane.pending_frame_id = 7;
        sibling_pane.attached = false;
        sibling_pane.pending_frame_id = 9;
        _ = model.beginPanePaste().?;
        _ = model.syncReportedPaneFocus().?;
        _ = try model.workspace.addCreated(.{
            .location = active,
            .position = 1,
            .label = "logs",
            .root_pane_id = active_pane,
        }, .{ .cols = 20, .rows = 5 });

        return .{
            .model = model,
            .target = target,
            .active = active,
            .root = root,
            .sibling = sibling,
            .active_pane = active_pane,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const Capture = struct {
    model: *client_model.Model,
    root: schema.PaneId,
    sibling: schema.PaneId,
    pending_pane: ?schema.PaneId,
    events: [16]Event = undefined,
    event_count: usize = 0,
    failure: Failure = .none,
    paste_available: bool = true,
    commit_deferred: bool = true,
    paste_observed_active: bool = false,
    focus_observed_committed: bool = false,
    pane_effects_observed_released: bool = true,

    fn pasteEffects(capture: *Capture) pane_paste.Effects {
        return .{ .context = capture, .deliver = deliverPaste };
    }

    fn focusEffects(capture: *Capture) pane_focus_reporting.Effects {
        return .{ .context = capture, .deliver = deliverFocus };
    }

    fn attachmentEffects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .attachment_pending = attachmentPending,
            .detach_pane = detachPane,
            .retire_attachment = retireAttachment,
            .hide_graphics = hideGraphics,
        };
    }

    fn deliverPaste(context: *anyopaque, delivery: pane_paste.Delivery) !bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.paste);
        capture.observeCommitDeferred();
        capture.paste_observed_active = capture.model.panePasteActive() and
            delivery == .marker and delivery.marker.boundary == .finish;

        if (capture.failure == .paste) {
            return error.PasteFailure;
        }

        return capture.paste_available;
    }

    fn deliverFocus(context: *anyopaque, delivery: pane_focus_reporting.Delivery) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.focus);
        capture.observeCommitDeferred();
        capture.focus_observed_committed = !capture.model.panePasteActive() and
            capture.model.reportedPaneFocus() == null and delivery.direction == .focus_out;

        if (capture.failure == .focus) {
            return error.FocusFailure;
        }
    }

    fn attachmentPending(context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.{ .pending = pane_id });
        capture.observePaneAuthorities();

        return capture.pending_pane == pane_id;
    }

    fn detachPane(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.{ .detach = pane_id });
        capture.observePaneAuthorities();

        if (capture.failure == .second_detach and pane_id == capture.sibling) {
            return error.DetachFailure;
        }
    }

    fn retireAttachment(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.{ .retire = pane_id });
        capture.observePaneAuthorities();
    }

    fn hideGraphics(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.{ .hide = pane_id });
        capture.observePaneAuthorities();

        if (capture.failure == .second_hide and pane_id == capture.sibling) {
            return error.HideFailure;
        }
    }

    fn observeCommitDeferred(capture: *Capture) void {
        const pane = capture.model.workspace.findPane(capture.root) orelse {
            capture.commit_deferred = false;
            return;
        };

        capture.commit_deferred = capture.commit_deferred and pane.attached and pane.pending_frame_id == 7;
    }

    fn observePaneAuthorities(capture: *Capture) void {
        capture.observeCommitDeferred();
        capture.pane_effects_observed_released = capture.pane_effects_observed_released and
            !capture.model.panePasteActive() and capture.model.reportedPaneFocus() == null;
    }

    fn record(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const Capture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn testingHandler(testing: *TestingModel, capture: *Capture) RetireTabAttachmentsHandler {
    return .{
        .model = testing.model,
        .paste_effects = capture.pasteEffects(),
        .focus_effects = capture.focusEffects(),
        .effects = capture.attachmentEffects(),
    };
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
