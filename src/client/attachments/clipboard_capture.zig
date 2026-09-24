//! Clipboard capture: captures clipboard media for an agent prompt through
//! the host.
const attachment_prompt = @import("../input/attachment_prompt.zig");
const data = @import("model");
const std = @import("std");
const clipboard_image = @import("../input/clipboard_image.zig");
const notifications = @import("../notifications/notifications.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const Client = @import("../execution/Client.zig");

/// Consumes one worker event and adopts only its current exact result.
/// Example: `try clipboard_capture.completeClipboardCapture(app, completion);`
pub fn completeClipboardCapture(client: *Client, completion: data.Completion) !void {
    var owned_capture: ?*data.Capture = null;
    defer if (owned_capture) |capture| {
        capture.deinit(client.gpa);
    };

    const command: clipboard_image.CompletionCommand = if (completion.result) |completed| completed: {
        const capture = client.model.clipboard.take(completed);
        owned_capture = capture;
        break :completed .{
            .succeeded = .{
                .execution_id = completion.execution_id,
                .result_id = @enumFromInt(capture.request.sequence),
                .target = capture.request.target,
            },
        };
    } else |err| .{
        .failed = .{
            .execution_id = completion.execution_id,
            .reason = err,
        },
    };

    const capture = client.model.clipboard.finish(command.executionId()) orelse
        return;

    const outcome: clipboard_image.CompletionOutcome = switch (command) {
        .failed => |failure| clipboard_image.classifyFailure(failure.reason),
        .succeeded => |result| result: {
            if (result.result_id != capture.id or !std.meta.eql(result.target, capture.target)) {
                break :result .stale;
            }

            const current = data.pane_attachment.focusedTarget(&client.model) orelse
                break :result .stale;
            if (!std.meta.eql(current, capture.target)) {
                break :result .stale;
            }

            const layout_changed = adoptClipboardCapture(client, owned_capture.?) catch |err| {
                break :result .{
                    .adoption_failed = err,
                };
            };
            owned_capture = null;
            if (layout_changed) {
                if (client.model.tabs.activeSlot()) |tab| {
                    try pane_resize.resizeAttachedPanes(client, tab, client.geometry().area);
                }
            }

            break :result .applied;
        },
    };
    try reportClipboardCapture(client, outcome);
}

/// Resolves the current target and schedules one best-effort media capture.
pub fn startClipboardCapture(model: *data.ClientModel) !clipboard_image.StartOutcome {
    if (!model.host.clipboard_capture) {
        return .unsupported;
    }

    const target = data.pane_attachment.focusedTarget(model) orelse return .no_target;
    const capture = (try model.clipboard.reserve(target)) orelse return .busy;
    errdefer {
        const rolled_back = model.clipboard.finish(capture.id);
        std.debug.assert(rolled_back != null);
    }

    try scheduleClipboardCapture(model, capture);
    return .{
        .started = capture,
    };
}

fn scheduleClipboardCapture(model: *data.ClientModel, capture: data.ClipboardCapture) !void {
    const request: data.CaptureRequest = .{
        .target = capture.target,
        .sequence = @intFromEnum(capture.id),
        .marker_policy = if (data.pane_attachment.markersFor(model, capture.target)) |markers|
            attachment_prompt.markerPolicy(markers)
        else
            .ordered,
    };

    try model.to_host.push(.{ .capture = request });
}

fn adoptClipboardCapture(client: *Client, capture: *data.Capture) !bool {
    const request = capture.request;
    const shelf = client.attachments orelse return error.AttachmentsUnsupported;
    var layout_changed = try shelf.adopt(capture);
    if (request.marker_policy.learnsIdentity()) {
        if (client.model.panes.findConst(request.target.pane_id)) |value| {
            layout_changed = layout_changed or (shelf.reconcileMarkers(
                request.target,
                .{
                    .buffer = &value.buffer,
                    .cursor = value.cursor,
                },
            ) orelse false);
        }
    }

    return layout_changed;
}

fn reportClipboardCapture(client: *Client, outcome: clipboard_image.CompletionOutcome) !void {
    const input: data.NotificationInput = switch (outcome) {
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

    try notifications.publishNotificationNow(client, input);
}
