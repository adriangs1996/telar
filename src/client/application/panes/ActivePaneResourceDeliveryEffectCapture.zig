const ModelType = @import("../../model/Model.zig");
const PaneFocusType = @import("../../model/PaneFocus.zig");
const RectType = @import("telar-core").Rect;
const TargetType = @import("../../attachments/AttachmentTarget.zig");
const active_pane_resource_delivery = @import("active_pane_resource_delivery.zig");
const AgentKeyType = @import("../../agents/AgentKey.zig");
const ActivePaneResourceDeliveryEffects = @import("ActivePaneResourceDeliveryEffects.zig");
const std = @import("std");
const EffectCapture = @This();

model: *const ModelType,
expected_focus: ?PaneFocusType = null,
attachment_area: ?RectType = null,
attachment_target: ?TargetType = null,
events: [7]active_pane_resource_delivery.Event = undefined,
event_count: usize = 0,
geometry_areas: [2]RectType = undefined,
geometry_count: usize = 0,
committed_focus_observed: bool = true,
failure: active_pane_resource_delivery.Failure = .none,
acknowledged: ?AgentKeyType = null,

pub fn effects(capture: *EffectCapture) ActivePaneResourceDeliveryEffects {
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

fn acknowledgeAgent(raw_context: *anyopaque, key: AgentKeyType) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.acknowledge_agent);
    capture.acknowledged = key;
}

fn syncAttachmentTarget(raw_context: *anyopaque, target: ?TargetType) ?RectType {
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

fn offerPaneGeometry(raw_context: *anyopaque, area: RectType) !void {
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

fn requestVisibleAttachments(raw_context: *anyopaque, _: RectType) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.request_attachments);

    if (capture.failure == .attachments) {
        return error.PaneAttachmentFailed;
    }
}

fn append(capture: *EffectCapture, event: active_pane_resource_delivery.Event) void {
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

pub fn eventSlice(capture: *const EffectCapture) []const active_pane_resource_delivery.Event {
    return capture.events[0..capture.event_count];
}
