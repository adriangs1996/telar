const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const workspace_attachment_retirement = @import("workspace_attachment_retirement.zig");
const RetireWorkspaceAttachmentsHandler = @import("RetireWorkspaceAttachmentsHandler.zig");
const pane_paste = @import("../input/pane_paste.zig");
const DeliveryType = @import("../panes/PaneFocusDelivery.zig");
const Capture = @This();

model: *ModelType,
pending_pane: ?PaneIdType,
fail_detach: ?PaneIdType = null,
events: [24]workspace_attachment_retirement.Event = undefined,
event_count: usize = 0,

pub fn handler(capture: *Capture) RetireWorkspaceAttachmentsHandler {
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

fn deliverFocus(context: *anyopaque, delivery: DeliveryType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    if (delivery.direction != .focus_out) {
        return error.UnexpectedFocusDirection;
    }
    capture.append(.{ .focus_out = delivery.pane_id });
}

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .attachment_pending = pane_id });

    return capture.pending_pane == pane_id;
}

fn detachPane(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .detach = pane_id });
    if (capture.fail_detach == pane_id) {
        return error.DetachFailed;
    }
}

fn retireAttachment(context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .retire_attachment = pane_id });
}

fn hideGraphics(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .hide_graphics = pane_id });
}

fn append(capture: *Capture, event: workspace_attachment_retirement.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const workspace_attachment_retirement.Event {
    return capture.events[0..capture.event_count];
}
