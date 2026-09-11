const ModelType = @import("../../model/Model.zig");
const TabSelectionType = @import("../../model/TabSelection.zig");
const PaneIdType = @import("telar-core").PaneId;
const tab_selection_delivery = @import("tab_selection_delivery.zig");
const PanePasteEffects = @import("../input/PanePasteEffects.zig");
const PaneFocusReportingEffects = @import("../panes/PaneFocusReportingEffects.zig");
const TabAttachmentRetirementEffects = @import("TabAttachmentRetirementEffects.zig");
const TabSelectionDeliveryEffects = @import("TabSelectionDeliveryEffects.zig");
const pane_paste = @import("../input/pane_paste.zig");
const DeliveryType = @import("../panes/PaneFocusDelivery.zig");
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const EffectsCapture = @This();

model: *ModelType,
selection: TabSelectionType,
previous_sibling: PaneIdType,
selected_sibling: PaneIdType,
events: [20]tab_selection_delivery.Event = undefined,
event_count: usize = 0,
committed_state_observed: bool = true,
paste_delivery_valid: bool = true,
focus_delivery_valid: bool = true,
failure: tab_selection_delivery.Failure = .none,

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

pub fn effects(capture: *EffectsCapture) TabSelectionDeliveryEffects {
    return .{
        .context = capture,
        .set_pane_graphics_visible = setPaneGraphicsVisible,
        .synchronize_active_resources = synchronizeActiveResources,
        .request_tab_snapshot = requestTabSnapshot,
    };
}

fn deliverPaste(context: *anyopaque, delivery: pane_paste.Delivery) !bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    switch (delivery) {
        .marker => |marker| {
            capture.append(.{ .paste_finish = marker.session.pane_id });
            capture.paste_delivery_valid = marker.boundary == .finish;
        },
        .content => {
            capture.paste_delivery_valid = false;
        },
    }

    return true;
}

fn deliverFocus(context: *anyopaque, delivery: DeliveryType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .focus_out = delivery.pane_id });
    capture.focus_delivery_valid = delivery.direction == .focus_out and
        capture.model.reportedPaneFocus() == null;
}

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .attachment_pending = pane_id });

    return false;
}

fn detachPane(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .detach = pane_id });
    if (capture.failure == .previous_detach and pane_id == capture.previous_sibling) {
        return error.PreviousDetachFailed;
    }
}

fn retireAttachment(context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .retire_attachment = pane_id });
}

fn hideGraphics(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .graphics_visibility = .{
        .pane_id = pane_id,
        .visible = false,
    } });
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .graphics_visibility = .{
        .pane_id = pane_id,
        .visible = visible,
    } });
    if (capture.failure == .selected_visibility and pane_id == capture.selected_sibling) {
        return error.SelectedVisibilityFailed;
    }
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.synchronize_active_resources);
    if (capture.failure == .active_resources) {
        return error.ActiveResourceSynchronizationFailed;
    }
}

fn requestTabSnapshot(context: *anyopaque, location: TabLocationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .request_tab_snapshot = location });
    if (capture.failure == .tab_snapshot) {
        return error.TabSnapshotRequestFailed;
    }
}

fn append(capture: *EffectsCapture, event: tab_selection_delivery.Event) void {
    capture.committed_state_observed = capture.committed_state_observed and capture.observesSelection();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observesSelection(capture: *const EffectsCapture) bool {
    const previous = capture.model.workspace.find(capture.selection.previous.tab_id) orelse return false;
    const selected = capture.model.workspace.find(capture.selection.selected.tab_id) orelse return false;
    const version = capture.model.version();

    return std.meta.eql(previous.location, capture.selection.previous) and
        std.meta.eql(selected.location, capture.selection.selected) and
        std.meta.eql(capture.model.activeTabLocation(), capture.selection.selected) and
        previous.model.layout.currentRevision() == capture.selection.previous_layout_revision and
        selected.model.layout.currentRevision() == capture.selection.selected_layout_revision and
        version.workspace == capture.selection.workspace_revision and
        version.tabs == capture.selection.tabs_revision and
        version.active_tab == capture.selection.active_tab_revision and
        version.panes == capture.selection.panes_revision and
        version.copy == capture.selection.copy_revision;
}

pub fn eventSlice(capture: *const EffectsCapture) []const tab_selection_delivery.Event {
    return capture.events[0..capture.event_count];
}
