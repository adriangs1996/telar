const Capture = @This();
const source_namespace = @import("pane_attachment_requests.zig");
const PaneAttachmentRequest = @import("PaneAttachmentRequest.zig");
const Effects = @import("PaneAttachmentRequestsEffects.zig");
pending: ?source_namespace.schema.PaneId = null,
requests: [4]PaneAttachmentRequest = undefined,
request_count: usize = 0,

pub fn effects(capture: *Capture) Effects {
    return .{
        .context = capture,
        .attachment_pending = attachmentPending,
        .request_attachment = requestAttachment,
    };
}

fn attachmentPending(raw_context: *anyopaque, pane_id: source_namespace.schema.PaneId) bool {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    return capture.pending == pane_id;
}

fn requestAttachment(raw_context: *anyopaque, request: PaneAttachmentRequest) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.requests[capture.request_count] = request;
    capture.request_count += 1;
}
