//! Adapts local clipboard media workers to client application state.

const Client = @import("../../Client.zig");
const ApplicationInputClipboardImageStartOutcome = @import("telar-client").ApplicationInputClipboardImageStartOutcome;
const StartClipboardImageHandlerType = @import("telar-client").StartClipboardImageHandler;
const capture_module = @import("../../../attachments/capture.zig");
const Completion = @import("Completion.zig");
const CompletionContext = @import("CompletionContext.zig");
const ApplicationInputClipboardImageCompletionCommand = @import("telar-client").ApplicationInputClipboardImageCompletionCommand;
const CompleteClipboardImageHandlerType = @import("telar-client").CompleteClipboardImageHandler;
const ClipboardCaptureType = @import("telar-client").ClipboardCapture;
const CaptureRequestType = @import("telar-client").CaptureRequest;
const markerPolicy_module = @import("telar-client").markerPolicy;
const std = @import("std");
const CaptureType = @import("telar-client").Capture;
const pane_geometry = @import("../panes/pane_geometry.zig");
const ApplicationInputClipboardImageCompletionOutcome = @import("telar-client").ApplicationInputClipboardImageCompletionOutcome;
const DeliverClipboardImageCompletionHandlerType = @import("telar-client").DeliverClipboardImageCompletionHandler;
const InputType = @import("telar-client").NotificationInput;
const notification_flow = @import("../notifications/notifications.zig");

/// Resolves the current target and schedules one best-effort media capture.
///
/// ```zig
/// _ = try start(client);
/// ```
pub fn start(client: *Client) !ApplicationInputClipboardImageStartOutcome {
    var use_case: StartClipboardImageHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .schedule = schedule,
        },
    };

    return use_case.execute(capture_module.platformSupported());
}

/// Consumes one worker event and adopts only its current exact result.
///
/// ```zig
/// try complete(client, completion);
/// ```
pub fn complete(client: *Client, completion: Completion) !void {
    var context: CompletionContext = .{ .client = client };
    defer if (context.capture) |capture| {
        capture.deinit(client.gpa);
    };

    const command: ApplicationInputClipboardImageCompletionCommand = if (completion.result) |completed| completed: {
        const capture = client.clipboard_capture_resources.take(completed);
        context.capture = capture;
        break :completed .{ .succeeded = .{
            .execution_id = completion.execution_id,
            .result_id = @enumFromInt(capture.request.sequence),
            .target = capture.request.target,
        } };
    } else |err| .{ .failed = .{
        .execution_id = completion.execution_id,
        .reason = err,
    } };
    var use_case: CompleteClipboardImageHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = &context,
            .adopt = adopt,
            .resize = resize,
        },
        .delivery = .{
            .context = &context,
            .deliver = deliverOutcome,
        },
    };

    _ = try use_case.execute(command);
}

fn schedule(raw_context: *anyopaque, capture: ClipboardCaptureType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const request: CaptureRequestType = .{
        .target = capture.target,
        .sequence = @intFromEnum(capture.id),
        .marker_policy = if (client.model.attachmentMarkers(capture.target)) |markers|
            markerPolicy_module(markers)
        else
            .ordered,
    };

    try client.select.concurrent(.clipboard_image, executeWorker, .{
        client.gpa,
        request,
        &client.clipboard_capture_resources.orphan,
    });
}

fn executeWorker(gpa: std.mem.Allocator, request: CaptureRequestType, orphan: *?*CaptureType) Completion {
    return .{
        .execution_id = @enumFromInt(request.sequence),
        .result = capture_module.captureClipboard(gpa, request, orphan),
    };
}

fn adopt(raw_context: *anyopaque) !bool {
    const context: *CompletionContext = @ptrCast(@alignCast(raw_context));
    const capture = context.capture orelse return error.ClipboardCaptureMissing;
    const request = capture.request;
    var layout_changed = try context.client.view.adoptAttachment(capture);
    context.capture = null;
    if (request.marker_policy.learnsIdentity()) {
        const tab = context.client.model.workspace.tabForPaneConst(request.target.pane_id);
        const pane = if (tab) |value| value.model.findConst(request.target.pane_id) else null;
        if (pane) |value| {
            layout_changed = layout_changed or (context.client.view.reconcileAttachmentMarkers(request.target, .{
                .buffer = &value.buffer,
                .cursor = value.cursor,
            }) orelse false);
        }
    }

    return layout_changed;
}

fn resize(raw_context: *anyopaque) !void {
    const context: *CompletionContext = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerActive(context.client, context.client.geometry().area);
}

fn deliverOutcome(raw_context: *anyopaque, outcome: ApplicationInputClipboardImageCompletionOutcome) !void {
    const context: *CompletionContext = @ptrCast(@alignCast(raw_context));
    var use_case: DeliverClipboardImageCompletionHandlerType = .{
        .effects = .{
            .context = context,
            .publish_notification = publishNotification,
        },
    };

    try use_case.execute(outcome);
}

fn publishNotification(raw_context: *anyopaque, input: InputType) !void {
    const context: *CompletionContext = @ptrCast(@alignCast(raw_context));

    try notification_flow.publishNow(context.client, input);
}
