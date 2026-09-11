const Capture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_attachment_retirement.zig");
const pane_paste = @import("../input/root.zig").pane_paste;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const Effects = @import("TabAttachmentRetirementEffects.zig");
const PendingAttachments = @import("PendingAttachments.zig");
model: *client_model.Model,
root: source_namespace.schema.PaneId,
sibling: source_namespace.schema.PaneId,
pending_pane: ?source_namespace.schema.PaneId,
events: [16]source_namespace.Event = undefined,
event_count: usize = 0,
failure: source_namespace.Failure = .none,
paste_available: bool = true,
commit_deferred: bool = true,
paste_observed_active: bool = false,
focus_observed_committed: bool = false,
pane_effects_observed_released: bool = true,

pub fn pasteEffects(capture: *Capture) pane_paste.Effects {
    return .{ .context = capture, .deliver = deliverPaste };
}

pub fn focusEffects(capture: *Capture) pane_focus_reporting.Effects {
    return .{ .context = capture, .deliver = deliverFocus };
}

pub fn attachmentEffects(capture: *Capture) Effects {
    return .{
        .context = capture,
        .attachment_pending = attachmentPending,
        .detach_pane = detachPane,
        .retire_attachment = retireAttachment,
        .hide_graphics = hideGraphics,
    };
}

pub fn pendingAttachments(capture: *Capture) PendingAttachments {
    return .{
        .context = capture,
        .pending = attachmentPending,
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

fn attachmentPending(context: *anyopaque, pane_id: source_namespace.schema.PaneId) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.{ .pending = pane_id });
    capture.observePaneAuthorities();

    return capture.pending_pane == pane_id;
}

fn detachPane(context: *anyopaque, pane_id: source_namespace.schema.PaneId) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.{ .detach = pane_id });
    capture.observePaneAuthorities();

    if (capture.failure == .second_detach and pane_id == capture.sibling) {
        return error.DetachFailure;
    }
}

fn retireAttachment(context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.{ .retire = pane_id });
    capture.observePaneAuthorities();
}

fn hideGraphics(context: *anyopaque, pane_id: source_namespace.schema.PaneId) !void {
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

fn record(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
