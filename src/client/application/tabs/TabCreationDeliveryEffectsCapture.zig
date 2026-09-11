const ModelType = @import("../../model/Model.zig");
const TabCreationType = @import("../../model/TabCreation.zig");
const PaneIdType = @import("telar-core").PaneId;
const tab_creation_delivery = @import("tab_creation_delivery.zig");
const PanePasteEffects = @import("../input/PanePasteEffects.zig");
const PaneFocusReportingEffects = @import("../panes/PaneFocusReportingEffects.zig");
const TabAttachmentRetirementEffects = @import("TabAttachmentRetirementEffects.zig");
const TabCreationDeliveryEffects = @import("TabCreationDeliveryEffects.zig");
const pane_paste = @import("../input/pane_paste.zig");
const DeliveryType = @import("../panes/PaneFocusDelivery.zig");
const std = @import("std");
const EffectsCapture = @This();

model: *ModelType,
creation: TabCreationType,
previous_root: PaneIdType,
previous_sibling: PaneIdType,
events: [20]tab_creation_delivery.Event = undefined,
event_count: usize = 0,
committed_creation_observed: bool = true,
previous_retired_before_sync: bool = false,
failure: tab_creation_delivery.Failure = .none,

pub fn pasteEffects(capture: *EffectsCapture) PanePasteEffects {
    return .{ .context = capture, .deliver = deliverPaste };
}

pub fn focusEffects(capture: *EffectsCapture) PaneFocusReportingEffects {
    return .{ .context = capture, .deliver = deliverFocus };
}

pub fn attachmentEffects(capture: *EffectsCapture) TabAttachmentRetirementEffects {
    return .{
        .context = capture,
        .attachment_pending = attachmentPending,
        .detach_pane = detachPane,
        .retire_attachment = retireAttachment,
        .hide_graphics = hideGraphics,
    };
}

pub fn effects(capture: *EffectsCapture) TabCreationDeliveryEffects {
    return .{
        .context = capture,
        .synchronize_active_resources = synchronizeActiveResources,
    };
}

fn deliverPaste(context: *anyopaque, delivery: pane_paste.Delivery) !bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const marker = switch (delivery) {
        .marker => |value| value,
        .content => return error.UnexpectedPasteContent,
    };
    capture.append(.{ .paste_finish = marker.session.pane_id });
    if (marker.boundary != .finish) {
        return error.UnexpectedPasteBoundary;
    }
    if (capture.failure == .paste) {
        return error.PasteFailed;
    }

    return true;
}

fn deliverFocus(context: *anyopaque, delivery: DeliveryType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .focus_out = delivery.pane_id });
    if (delivery.direction != .focus_out) {
        return error.UnexpectedFocusDirection;
    }
    if (capture.failure == .focus) {
        return error.FocusFailed;
    }
}

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .attachment_pending = pane_id });

    return false;
}

fn detachPane(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .detach = pane_id });
    if (capture.failure == .second_detach and pane_id == capture.previous_sibling) {
        return error.DetachFailed;
    }
}

fn retireAttachment(context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .retire_attachment = pane_id });
}

fn hideGraphics(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .hide_graphics = pane_id });
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.synchronize_active_resources);
    const root = capture.model.workspace.findPane(capture.previous_root).?;
    const sibling = capture.model.workspace.findPane(capture.previous_sibling).?;
    capture.previous_retired_before_sync = !root.attached and
        !sibling.attached and
        root.pending_frame_id == 0 and
        sibling.pending_frame_id == 0 and
        !capture.model.panePasteActive() and
        capture.model.reportedPaneFocus() == null;

    if (capture.failure == .active_resources) {
        return error.ActiveResourcesFailed;
    }
}

fn append(capture: *EffectsCapture, event: tab_creation_delivery.Event) void {
    capture.committed_creation_observed = capture.committed_creation_observed and capture.observesCreation();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observesCreation(capture: *const EffectsCapture) bool {
    const version = capture.model.version();
    const active = capture.model.activeTabLocation() orelse return false;

    return std.meta.eql(active, capture.creation.created) and
        version.workspace == capture.creation.workspace_revision and
        version.tabs == capture.creation.tabs_revision and
        version.active_tab == capture.creation.active_tab_revision and
        version.panes == capture.creation.panes_revision and
        version.copy == capture.creation.copy_revision;
}

pub fn eventSlice(capture: *const EffectsCapture) []const tab_creation_delivery.Event {
    return capture.events[0..capture.event_count];
}
