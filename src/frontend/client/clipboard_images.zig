//! Adapts local clipboard media workers to client application state.

const std = @import("std");
const attachments = @import("../attachments/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const clipboard_image = client_application.clipboard_image;

pub const Completion = struct {
    execution_id: client_model.ClipboardCaptureId,
    result: anyerror!*attachments.Capture,
};

pub const StartOutcome = union(enum) {
    started: client_model.ClipboardCapture,
    busy,
    unsupported,
    no_target,
};

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
    if (!attachments.platformSupported()) {
        return .unsupported;
    }

    const target = client.model.focusedAttachmentTarget() orelse return .no_target;
    var use_case: clipboard_image.StartClipboardImageHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .schedule = schedule,
        },
    };

    return switch (try use_case.execute(target)) {
        .started => |capture| .{ .started = capture },
        .busy => .busy,
    };
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
    };
    const outcome = try use_case.execute(command);

    try handleOutcome(client, outcome);
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
    const active = context.client.model.workspace.active() orelse return;

    try context.client.resizeAttached(&active.model, context.client.view.workbench());
}

fn handleOutcome(client: *Client, outcome: clipboard_image.CompletionOutcome) !void {
    switch (outcome) {
        .applied, .stale, .ignored, .no_image => {},
        .too_large => try client.notify(.{
            .level = .failure,
            .title = "Image preview skipped",
            .message = "The clipboard image exceeds Telar's local preview limit",
        }),
        .worker_failed => |err| try client.notify(.{
            .level = .failure,
            .title = "Image preview failed",
            .message = @errorName(err),
        }),
        .adoption_failed => |err| try client.notify(.{
            .level = .failure,
            .title = "Image preview failed",
            .message = @errorName(err),
        }),
    }
}
