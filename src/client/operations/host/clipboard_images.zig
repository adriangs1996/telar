//! Adapts local clipboard media workers to client application state.

const std = @import("std");
const clipboard_image = @import("../../application/input/clipboard_image.zig");
const Client = @import("../../AttachedClient.zig");
const ApplicationInputClipboardImageStartOutcome = @import("../../application/input/clipboard_image.zig").StartOutcome;
const Completion = @import("Completion.zig");
const CompletionContext = @import("CompletionContext.zig");
const ApplicationInputClipboardImageCompletionCommand = @import("../../application/input/clipboard_image.zig").CompletionCommand;
const ClipboardCaptureType = @import("../../model/ClipboardCapture.zig");
const CaptureRequestType = @import("../../attachments/CaptureRequest.zig");
const markerPolicy_module = @import("../../application/input/attachment_prompt.zig").markerPolicy;
const pane_geometry = @import("../panes/pane_geometry.zig");
const ApplicationInputClipboardImageCompletionOutcome = @import("../../application/input/clipboard_image.zig").CompletionOutcome;
const InputType = @import("../../notifications/NotificationInput.zig");
const notification_flow = @import("../notifications/notifications.zig");

/// Resolves the current target and schedules one best-effort media capture.
///
/// ```zig
/// _ = try start(client);
/// ```
pub fn start(client: *Client) !ApplicationInputClipboardImageStartOutcome {
    if (!client.capture_port.platformSupported()) {
        return .unsupported;
    }

    const target = client.model.focusedAttachmentTarget() orelse return .no_target;
    const capture = (try client.model.beginClipboardCapture(target)) orelse return .busy;
    errdefer {
        const rolled_back = client.model.finishClipboardCapture(capture.id);
        std.debug.assert(rolled_back != null);
    }

    try schedule(client, capture);
    return .{ .started = capture };
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

    const capture = client.model.finishClipboardCapture(command.executionId()) orelse
        return;

    const outcome: ApplicationInputClipboardImageCompletionOutcome = switch (command) {
        .failed => |failure| clipboard_image.classifyFailure(failure.reason),
        .succeeded => |result| result: {
            if (result.result_id != capture.id or !std.meta.eql(result.target, capture.target)) {
                break :result .stale;
            }

            const current = client.model.focusedAttachmentTarget() orelse
                break :result .stale;
            if (!std.meta.eql(current, capture.target)) {
                break :result .stale;
            }

            const layout_changed = adopt(&context) catch |err| {
                break :result .{ .adoption_failed = err };
            };
            if (layout_changed) {
                try pane_geometry.offerActive(client, client.geometry().area);
            }

            break :result .applied;
        },
    };
    try deliverOutcome(client, outcome);
}

fn schedule(client: *Client, capture: ClipboardCaptureType) !void {
    const request: CaptureRequestType = .{
        .target = capture.target,
        .sequence = @intFromEnum(capture.id),
        .marker_policy = if (client.model.attachmentMarkers(capture.target)) |markers|
            markerPolicy_module(markers)
        else
            .ordered,
    };

    try client.capture_port.schedule(request);
}

fn adopt(context: *CompletionContext) !bool {
    const capture = context.capture orelse return error.ClipboardCaptureMissing;
    const request = capture.request;
    var layout_changed = try context.client.attachment_shelf.adopt(capture);
    context.capture = null;
    if (request.marker_policy.learnsIdentity()) {
        const tab = context.client.model.workspace.tabForPaneConst(request.target.pane_id);
        const pane = if (tab) |value| value.model.findConst(request.target.pane_id) else null;
        if (pane) |value| {
            layout_changed = layout_changed or (context.client.attachment_shelf.reconcileMarkers(request.target, .{
                .buffer = &value.buffer,
                .cursor = value.cursor,
            }) orelse false);
        }
    }

    return layout_changed;
}

fn deliverOutcome(client: *Client, outcome: ApplicationInputClipboardImageCompletionOutcome) !void {
    const input: InputType = switch (outcome) {
        .applied, .stale, .ignored, .no_image => return,
        .too_large => .{
            .level = .failure,
            .title = "Image preview skipped",
            .message = "The clipboard image exceeds Telar's local preview limit",
        },
        .worker_failed, .adoption_failed => |err| .{
            .level = .failure,
            .title = "Image preview failed",
            .message = @errorName(err),
        },
    };

    try notification_flow.publishNow(client, input);
}
