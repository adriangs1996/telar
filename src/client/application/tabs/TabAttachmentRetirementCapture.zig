const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");
const PanePasteEffects = @import("../input/PanePasteEffects.zig");
const PaneFocusReportingEffects = @import("../panes/PaneFocusReportingEffects.zig");
const TabAttachmentRetirementEffects = @import("TabAttachmentRetirementEffects.zig");
const PendingAttachments = @import("PendingAttachments.zig");
const pane_paste = @import("../input/pane_paste.zig");
const DeliveryType = @import("../panes/PaneFocusDelivery.zig");
const Capture = @This();

model: *ModelType,
root: PaneIdType,
sibling: PaneIdType,
pending_pane: ?PaneIdType,
events: [16]tab_attachment_retirement.Event = undefined,
event_count: usize = 0,
failure: tab_attachment_retirement.Failure = .none,
paste_available: bool = true,
commit_deferred: bool = true,
paste_observed_active: bool = false,
focus_observed_committed: bool = false,
pane_effects_observed_released: bool = true,

pub fn pasteEffects(capture: *Capture) PanePasteEffects {
    return .{ .context = capture, .deliver = deliverPaste };
}

pub fn focusEffects(capture: *Capture) PaneFocusReportingEffects {
    return .{ .context = capture, .deliver = deliverFocus };
}

pub fn attachmentEffects(capture: *Capture) TabAttachmentRetirementEffects {
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

fn deliverFocus(context: *anyopaque, delivery: DeliveryType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.focus);
    capture.observeCommitDeferred();
    capture.focus_observed_committed = !capture.model.panePasteActive() and
        capture.model.reportedPaneFocus() == null and delivery.direction == .focus_out;

    if (capture.failure == .focus) {
        return error.FocusFailure;
    }
}

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.{ .pending = pane_id });
    capture.observePaneAuthorities();

    return capture.pending_pane == pane_id;
}

fn detachPane(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.{ .detach = pane_id });
    capture.observePaneAuthorities();

    if (capture.failure == .second_detach and pane_id == capture.sibling) {
        return error.DetachFailure;
    }
}

fn retireAttachment(context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.{ .retire = pane_id });
    capture.observePaneAuthorities();
}

fn hideGraphics(context: *anyopaque, pane_id: PaneIdType) !void {
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

fn record(capture: *Capture, event: tab_attachment_retirement.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const tab_attachment_retirement.Event {
    return capture.events[0..capture.event_count];
}
