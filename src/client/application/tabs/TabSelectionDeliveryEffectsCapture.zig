const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_selection_delivery.zig");
const pane_paste = @import("../input/root.zig").pane_paste;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");
const Effects = @import("TabSelectionDeliveryEffects.zig");
const std = @import("std");
model: *client_model.Model,
selection: client_model.TabSelection,
previous_sibling: source_namespace.schema.PaneId,
selected_sibling: source_namespace.schema.PaneId,
events: [20]source_namespace.Event = undefined,
event_count: usize = 0,
committed_state_observed: bool = true,
paste_delivery_valid: bool = true,
focus_delivery_valid: bool = true,
failure: source_namespace.Failure = .none,

pub fn pasteEffects(capture: *EffectsCapture) pane_paste.Effects {
    return .{ .context = capture, .deliver = deliverPaste };
}

pub fn focusEffects(capture: *EffectsCapture) pane_focus_reporting.Effects {
    return .{ .context = capture, .deliver = deliverFocus };
}

pub fn attachmentEffects(capture: *EffectsCapture) tab_attachment_retirement.Effects {
    return .{
        .context = capture,
        .attachment_pending = attachmentPending,
        .detach_pane = detachPane,
        .retire_attachment = retireAttachment,
        .hide_graphics = hideGraphics,
    };
}

pub fn effects(capture: *EffectsCapture) Effects {
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

fn deliverFocus(context: *anyopaque, delivery: pane_focus_reporting.Delivery) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .focus_out = delivery.pane_id });
    capture.focus_delivery_valid = delivery.direction == .focus_out and
        capture.model.reportedPaneFocus() == null;
}

fn attachmentPending(context: *anyopaque, pane_id: source_namespace.schema.PaneId) bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .attachment_pending = pane_id });

    return false;
}

fn detachPane(context: *anyopaque, pane_id: source_namespace.schema.PaneId) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .detach = pane_id });
    if (capture.failure == .previous_detach and pane_id == capture.previous_sibling) {
        return error.PreviousDetachFailed;
    }
}

fn retireAttachment(context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .retire_attachment = pane_id });
}

fn hideGraphics(context: *anyopaque, pane_id: source_namespace.schema.PaneId) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .graphics_visibility = .{
        .pane_id = pane_id,
        .visible = false,
    } });
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: source_namespace.schema.PaneId, visible: bool) !void {
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

fn requestTabSnapshot(context: *anyopaque, location: source_namespace.schema.TabLocation) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .request_tab_snapshot = location });
    if (capture.failure == .tab_snapshot) {
        return error.TabSnapshotRequestFailed;
    }
}

fn append(capture: *EffectsCapture, event: source_namespace.Event) void {
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

pub fn eventSlice(capture: *const EffectsCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
