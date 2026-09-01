//! Application policy for retiring every tab attachment in the current
//! client workspace before a handoff.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");
const pane_focus_reporting = @import("../panes/pane_focus_reporting.zig");
const pane_paste = @import("../input/pane_paste.zig");
const tab_attachment_retirement = @import("../tabs/tab_attachment_retirement.zig");

const schema = core.schema;

pub const RetireWorkspaceAttachmentsHandler = struct {
    model: *client_model.Model,
    paste_effects: pane_paste.Effects,
    focus_effects: pane_focus_reporting.Effects,
    attachment_effects: tab_attachment_retirement.Effects,

    /// Retires each tab's client-owned authorities and attachments in stable
    /// workspace order without changing semantic presentation state.
    ///
    /// ```zig
    /// try handler.execute();
    /// ```
    pub fn execute(handler: *RetireWorkspaceAttachmentsHandler) !void {
        var tabs = handler.model.workspace.tabIterator();
        while (tabs.next()) |tab| {
            var retire: tab_attachment_retirement.RetireTabAttachmentsHandler = .{
                .model = handler.model,
                .paste_effects = handler.paste_effects,
                .focus_effects = handler.focus_effects,
                .effects = handler.attachment_effects,
            };

            try retire.execute(tab.location);
        }
    }
};

const Event = union(enum) {
    attachment_pending: schema.PaneId,
    paste_finish: schema.PaneId,
    focus_out: schema.PaneId,
    detach: schema.PaneId,
    retire_attachment: schema.PaneId,
    hide_graphics: schema.PaneId,
};

const TestingModel = struct {
    model: *client_model.Model,
    root: schema.PaneId,
    sibling: schema.PaneId,
    other_root: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const active: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
        const other: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
        const root: schema.PaneId = @enumFromInt(1);
        const sibling: schema.PaneId = @enumFromInt(2);
        const other_root: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(root, active, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(root, sibling, active, .horizontal, .{ .w = 40, .h = 10 });
        _ = try model.workspace.addCreated(.{
            .location = other,
            .position = 1,
            .label = "other",
            .root_pane_id = other_root,
        }, .{ .cols = 40, .rows = 10 });
        if (!model.workspace.select(active.tab_id)) {
            return error.ActiveTabNotRestored;
        }
        if (!model.workspace.active().?.model.focusPane(root)) {
            return error.ActiveFocusNotRestored;
        }

        const root_pane = model.workspace.findPane(root).?;
        root_pane.input_modes.bracketed_paste = true;
        root_pane.input_modes.focus_events = true;
        model.workspace.findPane(sibling).?.attached = false;
        _ = model.beginPanePaste().?;
        _ = model.syncReportedPaneFocus().?;

        return .{
            .model = model,
            .root = root,
            .sibling = sibling,
            .other_root = other_root,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const Capture = struct {
    model: *client_model.Model,
    pending_pane: ?schema.PaneId,
    fail_detach: ?schema.PaneId = null,
    events: [24]Event = undefined,
    event_count: usize = 0,

    fn handler(capture: *Capture) RetireWorkspaceAttachmentsHandler {
        return .{
            .model = capture.model,
            .paste_effects = .{ .context = capture, .deliver = deliverPaste },
            .focus_effects = .{ .context = capture, .deliver = deliverFocus },
            .attachment_effects = .{
                .context = capture,
                .attachment_pending = attachmentPending,
                .detach_pane = detachPane,
                .retire_attachment = retireAttachment,
                .hide_graphics = hideGraphics,
            },
        };
    }

    fn deliverPaste(context: *anyopaque, delivery: pane_paste.Delivery) !bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        const marker = switch (delivery) {
            .marker => |value| value,
            .content => return error.UnexpectedPasteContent,
        };
        if (marker.boundary != .finish) {
            return error.UnexpectedPasteBoundary;
        }
        capture.append(.{ .paste_finish = marker.session.pane_id });

        return true;
    }

    fn deliverFocus(context: *anyopaque, delivery: pane_focus_reporting.Delivery) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        if (delivery.direction != .focus_out) {
            return error.UnexpectedFocusDirection;
        }
        capture.append(.{ .focus_out = delivery.pane_id });
    }

    fn attachmentPending(context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.{ .attachment_pending = pane_id });

        return capture.pending_pane == pane_id;
    }

    fn detachPane(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.{ .detach = pane_id });
        if (capture.fail_detach == pane_id) {
            return error.DetachFailed;
        }
    }

    fn retireAttachment(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.{ .retire_attachment = pane_id });
    }

    fn hideGraphics(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.{ .hide_graphics = pane_id });
    }

    fn append(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const Capture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

test "RetireWorkspaceAttachmentsHandler retires every tab in stable order" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
    };
    var handler = capture.handler();

    try handler.execute();

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .paste_finish = testing.root },
        .{ .focus_out = testing.root },
        .{ .attachment_pending = testing.root },
        .{ .detach = testing.root },
        .{ .retire_attachment = testing.root },
        .{ .hide_graphics = testing.root },
        .{ .attachment_pending = testing.sibling },
        .{ .detach = testing.sibling },
        .{ .retire_attachment = testing.sibling },
        .{ .hide_graphics = testing.sibling },
        .{ .attachment_pending = testing.other_root },
        .{ .detach = testing.other_root },
        .{ .retire_attachment = testing.other_root },
        .{ .hide_graphics = testing.other_root },
    }, capture.eventSlice());
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expect(!testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.other_root).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RetireWorkspaceAttachmentsHandler preserves completed tabs on failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .fail_detach = testing.other_root,
    };
    var handler = capture.handler();

    try std.testing.expectError(error.DetachFailed, handler.execute());

    try std.testing.expectEqualDeep(Event{ .detach = testing.other_root }, capture.eventSlice()[capture.event_count - 1]);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expect(!testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.other_root).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RetireWorkspaceAttachmentsHandler accepts an empty projection" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{
        .model = &model,
        .pending_pane = null,
    };
    var handler = capture.handler();

    try handler.execute();

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}
