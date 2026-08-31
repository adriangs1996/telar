//! Application policy for preflighting and retiring every current workspace
//! attachment before a handoff request.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");
const pane_focus_reporting = @import("pane_focus_reporting.zig");
const pane_paste = @import("pane_paste.zig");
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");

const schema = core.schema;

pub const Capacity = struct {
    context: *anyopaque,
    available: *const fn (*anyopaque) usize,
};

pub const PrepareWorkspaceHandoffHandler = struct {
    model: *client_model.Model,
    capacity: Capacity,
    paste_effects: pane_paste.Effects,
    focus_effects: pane_focus_reporting.Effects,
    attachment_effects: tab_attachment_retirement.Effects,

    /// Reserves the closing paste marker, focus-out, every attached or
    /// in-flight pane detach and the final open request before retiring tabs.
    ///
    /// ```zig
    /// try handler.execute();
    /// ```
    pub fn execute(handler: *PrepareWorkspaceHandoffHandler) !void {
        const required_capacity = try handler.requiredCapacity();
        if (required_capacity > handler.capacity.available(handler.capacity.context)) {
            return error.ClientOutboxFull;
        }

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

    fn requiredCapacity(handler: *const PrepareWorkspaceHandoffHandler) !usize {
        var required: usize = 1;
        const pending_attachments: tab_attachment_retirement.PendingAttachments = .{
            .context = handler.attachment_effects.context,
            .pending = handler.attachment_effects.attachment_pending,
        };

        var tabs = handler.model.workspace.tabIterator();
        while (tabs.next()) |tab| {
            const plan = try handler.model.planTabDetachment(tab.location);
            required += tab_attachment_retirement.requiredDeliveryCapacity(&plan, pending_attachments);
        }

        return required;
    }
};

const Event = union(enum) {
    attachment_pending: schema.PaneId,
    available_capacity,
    paste_finish: schema.PaneId,
    focus_out: schema.PaneId,
    detach: schema.PaneId,
    retire_attachment: schema.PaneId,
    hide_graphics: schema.PaneId,
};

const TestingModel = struct {
    model: *client_model.Model,
    active: schema.TabLocation,
    other: schema.TabLocation,
    root: schema.PaneId,
    sibling: schema.PaneId,
    other_root: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const active: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const other: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const root: schema.PaneId = @enumFromInt(1);
        const sibling: schema.PaneId = @enumFromInt(2);
        const other_root: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(root, active, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(
            root,
            sibling,
            active,
            .horizontal,
            .{ .w = 40, .h = 10 },
        );
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
            .active = active,
            .other = other,
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
    available: usize,
    fail_detach: ?schema.PaneId = null,
    events: [32]Event = undefined,
    event_count: usize = 0,
    queries_observed_unchanged: bool = true,

    fn capacity(capture: *Capture) Capacity {
        return .{ .context = capture, .available = availableCapacity };
    }

    fn pasteEffects(capture: *Capture) pane_paste.Effects {
        return .{ .context = capture, .deliver = deliverPaste };
    }

    fn focusEffects(capture: *Capture) pane_focus_reporting.Effects {
        return .{ .context = capture, .deliver = deliverFocus };
    }

    fn attachmentEffects(capture: *Capture) tab_attachment_retirement.Effects {
        return .{
            .context = capture,
            .attachment_pending = attachmentPending,
            .detach_pane = detachPane,
            .retire_attachment = retireAttachment,
            .hide_graphics = hideGraphics,
        };
    }

    fn availableCapacity(context: *anyopaque) usize {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.available_capacity);

        return capture.available;
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
        capture.queries_observed_unchanged = capture.queries_observed_unchanged and
            capture.model.panePasteActive() and
            capture.model.reportedPaneFocus() != null and
            capture.model.workspace.findPane(pane_id) != null;
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

fn handlerFor(testing: *TestingModel, capture: *Capture) PrepareWorkspaceHandoffHandler {
    return .{
        .model = testing.model,
        .capacity = capture.capacity(),
        .paste_effects = capture.pasteEffects(),
        .focus_effects = capture.focusEffects(),
        .attachment_effects = capture.attachmentEffects(),
    };
}

test "PrepareWorkspaceHandoffHandler reserves pending detaches before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 5,
    };
    var handler = handlerFor(&testing, &capture);

    try std.testing.expectError(error.ClientOutboxFull, handler.execute());

    try std.testing.expectEqualSlices(Event, &.{
        .{ .attachment_pending = testing.root },
        .{ .attachment_pending = testing.sibling },
        .{ .attachment_pending = testing.other_root },
        .available_capacity,
    }, capture.eventSlice());
    try std.testing.expect(capture.queries_observed_unchanged);
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.other_root).?.attached);
}

test "PrepareWorkspaceHandoffHandler retires every tab at exact capacity" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 6,
    };
    var handler = handlerFor(&testing, &capture);

    try handler.execute();

    try std.testing.expectEqualSlices(Event, &.{
        .{ .attachment_pending = testing.root },
        .{ .attachment_pending = testing.sibling },
        .{ .attachment_pending = testing.other_root },
        .available_capacity,
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
}

test "PrepareWorkspaceHandoffHandler preserves deferred tab commits after detach failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 6,
        .fail_detach = testing.sibling,
    };
    var handler = handlerFor(&testing, &capture);

    try std.testing.expectError(error.DetachFailed, handler.execute());

    try std.testing.expectEqualDeep(
        Event{ .detach = testing.sibling },
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.other_root).?.attached);
}
