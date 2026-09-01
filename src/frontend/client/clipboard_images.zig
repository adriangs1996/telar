//! Adapts local clipboard media workers to client application state.

const std = @import("std");
const attachments = @import("../attachments/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const notification_capability = @import("../notifications/root.zig");
const notification_flow = @import("notifications.zig");
const pane_geometry = @import("pane_geometry.zig");

const Client = @import("client.zig");
const clipboard_image = client_application.clipboard_image;
const clipboard_image_delivery = client_application.clipboard_image_delivery;

pub const Completion = struct {
    execution_id: client_model.ClipboardCaptureId,
    result: anyerror!*attachments.Capture,
};

pub const StartOutcome = clipboard_image.StartOutcome;

const CompletionContext = struct {
    client: *Client,
    capture: ?*attachments.Capture = null,
};

/// Resolves the current target and schedules one best-effort media capture.
///
/// ```zig
/// _ = try start(client);
/// ```
pub fn start(client: *Client) !StartOutcome {
    var use_case: clipboard_image.StartClipboardImageHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .schedule = schedule,
        },
    };

    return use_case.execute(attachments.platformSupported());
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

    const command: clipboard_image.CompletionCommand = if (completion.result) |completed| completed: {
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
    var use_case: clipboard_image.CompleteClipboardImageHandler = .{
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

fn schedule(raw_context: *anyopaque, capture: client_model.ClipboardCapture) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const request: attachments.CaptureRequest = .{
        .target = capture.target,
        .sequence = @intFromEnum(capture.id),
    };

    try client.select.concurrent(.clipboard_image, executeWorker, .{
        client.gpa,
        request,
        &client.clipboard_capture_resources.orphan,
    });
}

fn executeWorker(gpa: std.mem.Allocator, request: attachments.CaptureRequest, orphan: *?*attachments.Capture) Completion {
    return .{
        .execution_id = @enumFromInt(request.sequence),
        .result = attachments.captureClipboard(gpa, request, orphan),
    };
}

fn adopt(raw_context: *anyopaque) !bool {
    const context: *CompletionContext = @ptrCast(@alignCast(raw_context));
    const capture = context.capture orelse return error.ClipboardCaptureMissing;
    const layout_changed = try context.client.view.adoptAttachment(capture);
    context.capture = null;

    return layout_changed;
}

fn resize(raw_context: *anyopaque) !void {
    const context: *CompletionContext = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerActive(context.client, context.client.view.workbench());
}

fn deliverOutcome(raw_context: *anyopaque, outcome: clipboard_image.CompletionOutcome) !void {
    const context: *CompletionContext = @ptrCast(@alignCast(raw_context));
    var use_case: clipboard_image_delivery.DeliverClipboardImageCompletionHandler = .{
        .effects = .{
            .context = context,
            .publish_notification = publishNotification,
        },
    };

    try use_case.execute(outcome);
}

fn publishNotification(raw_context: *anyopaque, input: notification_capability.Input) !void {
    const context: *CompletionContext = @ptrCast(@alignCast(raw_context));

    try notification_flow.publishNow(context.client, input);
}
