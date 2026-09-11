const EffectCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("active_pane_resource_delivery.zig");
const attachments = @import("../../attachments/root.zig");
const agents = @import("../../root.zig").agents;
const Effects = @import("ActivePaneResourceDeliveryEffects.zig");
const std = @import("std");
model: *const client_model.Model,
expected_focus: ?client_model.PaneFocus = null,
attachment_area: ?source_namespace.ui.Rect = null,
attachment_target: ?attachments.Target = null,
events: [7]source_namespace.Event = undefined,
event_count: usize = 0,
geometry_areas: [2]source_namespace.ui.Rect = undefined,
geometry_count: usize = 0,
committed_focus_observed: bool = true,
failure: source_namespace.Failure = .none,
acknowledged: ?agents.AgentKey = null,

pub fn effects(capture: *EffectCapture) Effects {
    return .{
        .context = capture,
        .sync_attachment_target = syncAttachmentTarget,
        .sync_focus_reporting = syncFocusReporting,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .offer_pane_geometry = offerPaneGeometry,
        .request_visible_attachments = requestVisibleAttachments,
        .acknowledge_agent = acknowledgeAgent,
    };
}

fn acknowledgeAgent(raw_context: *anyopaque, key: agents.AgentKey) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.acknowledge_agent);
    capture.acknowledged = key;
}

fn syncAttachmentTarget(raw_context: *anyopaque, target: ?attachments.Target) ?source_namespace.ui.Rect {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.attachment_target);
    capture.attachment_target = target;

    return capture.attachment_area;
}

fn syncFocusReporting(raw_context: *anyopaque) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.focus_reporting);

    if (capture.failure == .focus_reporting) {
        return error.FocusReportingFailed;
    }
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.invalidate_placements);
}

fn offerPaneGeometry(raw_context: *anyopaque, area: source_namespace.ui.Rect) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.pane_geometry);
    capture.geometry_areas[capture.geometry_count] = area;
    capture.geometry_count += 1;

    if (capture.failure == .first_geometry and capture.geometry_count == 1) {
        return error.PaneGeometryFailed;
    }
    if (capture.failure == .second_geometry and capture.geometry_count == 2) {
        return error.PaneGeometryFailed;
    }
}

fn requestVisibleAttachments(raw_context: *anyopaque, _: source_namespace.ui.Rect) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.request_attachments);

    if (capture.failure == .attachments) {
        return error.PaneAttachmentFailed;
    }
}

fn append(capture: *EffectCapture, event: source_namespace.Event) void {
    capture.observeFocus();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observeFocus(capture: *EffectCapture) void {
    const focus = capture.expected_focus orelse return;
    const active = capture.model.workspace.activeConst() orelse {
        capture.committed_focus_observed = false;
        return;
    };

    capture.committed_focus_observed = capture.committed_focus_observed and
        std.meta.eql(active.location, focus.location) and
        active.model.layout.focused() == focus.focused and
        capture.model.version().panes == focus.panes_revision;
}

pub fn eventSlice(capture: *const EffectCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
