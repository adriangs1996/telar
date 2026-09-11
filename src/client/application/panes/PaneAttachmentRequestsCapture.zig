const PaneIdType = @import("telar-core").PaneId;
const PaneAttachmentRequest = @import("PaneAttachmentRequest.zig");
const PaneAttachmentRequestsEffects = @import("PaneAttachmentRequestsEffects.zig");
const Capture = @This();

pending: ?PaneIdType = null,
requests: [4]PaneAttachmentRequest = undefined,
request_count: usize = 0,

pub fn effects(capture: *Capture) PaneAttachmentRequestsEffects {
    return .{
        .context = capture,
        .attachment_pending = attachmentPending,
        .request_attachment = requestAttachment,
    };
}

fn attachmentPending(raw_context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    return capture.pending == pane_id;
}

fn requestAttachment(raw_context: *anyopaque, request: PaneAttachmentRequest) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.requests[capture.request_count] = request;
    capture.request_count += 1;
}
