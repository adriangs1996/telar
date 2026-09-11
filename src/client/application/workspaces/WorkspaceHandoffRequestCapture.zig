const ModelType = @import("../../model/Model.zig");
const workspace_handoff = @import("workspace_handoff.zig");
const WorkspaceHandoff = @import("WorkspaceHandoff.zig");
const WorkspaceDepartureType = @import("../../model/WorkspaceDeparture.zig");
const AdmitWorkspaceHandoffHandlerType = @import("AdmitWorkspaceHandoffHandler.zig");
const HandoffRequestEffects = @import("HandoffRequestEffects.zig");
const PrepareWorkspaceHandoffHandlerType = @import("PrepareWorkspaceHandoffHandler.zig");
const RetireWorkspaceAttachmentsHandlerType = @import("RetireWorkspaceAttachmentsHandler.zig");
const RestoreWorkspaceHandoffHandlerType = @import("RestoreWorkspaceHandoffHandler.zig");
const std = @import("std");
const pane_paste = @import("../input/pane_paste.zig");
const DeliveryType = @import("../panes/PaneFocusDelivery.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const RequestCapture = @This();

model: *ModelType,
blocked: bool = false,
fail_prepare: bool = false,
fail_detach: bool = false,
fail_send: bool = false,
fail_restore: bool = false,
events: [7]workspace_handoff.RequestEvent = undefined,
event_count: usize = 0,
command: ?WorkspaceHandoff = null,
departure: ?WorkspaceDepartureType = null,
observed_commit: bool = false,

pub fn admission(capture: *RequestCapture) AdmitWorkspaceHandoffHandlerType {
    return .{
        .model = capture.model,
        .gate = .{ .context = capture, .pending = pending },
    };
}

pub fn port(capture: *RequestCapture) HandoffRequestEffects {
    return .{
        .context = capture,
        .send = send,
        .release = release,
    };
}

pub fn preparation(capture: *RequestCapture) PrepareWorkspaceHandoffHandlerType {
    return .{
        .model = capture.model,
        .requests = .{
            .context = capture,
            .ensure = ensureRequests,
        },
        .deliveries = .{
            .context = capture,
            .available = availableDeliveries,
        },
        .pending_attachments = .{
            .context = capture,
            .pending = attachmentPending,
        },
    };
}

pub fn retirement(capture: *RequestCapture) RetireWorkspaceAttachmentsHandlerType {
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

pub fn restoration(capture: *RequestCapture) RestoreWorkspaceHandoffHandlerType {
    return .{
        .effects = .{
            .context = capture,
            .show_pane_graphics = showPaneGraphics,
        },
        .snapshots = .{ .effects = .{
            .context = capture,
            .pending = tabSnapshotPending,
            .request = requestTabSnapshot,
        } },
    };
}

fn pending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    return capture.blocked;
}

fn record(capture: *RequestCapture, event: workspace_handoff.RequestEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn ensureRequests(context: *anyopaque, _: u64) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.prepare);
    if (capture.fail_prepare) {
        return error.PreparationFailed;
    }
}

fn availableDeliveries(_: *anyopaque) usize {
    return std.math.maxInt(usize);
}

fn deliverPaste(_: *anyopaque, _: pane_paste.Delivery) !bool {
    return true;
}

fn deliverFocus(_: *anyopaque, _: DeliveryType) !void {}

fn attachmentPending(_: *anyopaque, _: PaneIdType) bool {
    return false;
}

fn detachPane(context: *anyopaque, _: PaneIdType) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.detach);
    if (capture.fail_detach) {
        return error.DetachFailed;
    }
}

fn retireAttachment(_: *anyopaque, _: PaneIdType) void {}

fn hideGraphics(_: *anyopaque, _: PaneIdType) !void {}

fn send(context: *anyopaque, command: WorkspaceHandoff) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.send);
    capture.command = command;
    if (capture.fail_send) {
        return error.SendFailed;
    }
}

fn showPaneGraphics(context: *anyopaque, _: PaneIdType) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.restore_graphics);
    if (capture.fail_restore) {
        return error.RestoreFailed;
    }
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.restore_snapshot_pending);

    return false;
}

fn requestTabSnapshot(context: *anyopaque, _: TabLocationType) !void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.restore_snapshot);
}

fn release(context: *anyopaque, departure: *const WorkspaceDepartureType) void {
    const capture: *RequestCapture = @ptrCast(@alignCast(context));
    capture.record(.release);
    capture.departure = departure.*;
    capture.observed_commit = capture.model.workspaceLocation() == null and
        capture.model.version().workspace == 1;
}
