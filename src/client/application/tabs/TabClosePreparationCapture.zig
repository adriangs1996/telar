const Capture = @This();
const source_namespace = @import("tab_close_preparation.zig");
const PrepareTabCloseHandler = @import("PrepareTabCloseHandler.zig");
pending_pane: ?source_namespace.schema.PaneId,
available: usize,
request_failure: ?anyerror = null,
events: [4]source_namespace.Event = undefined,
event_count: usize = 0,

pub fn handler(capture: *Capture) PrepareTabCloseHandler {
    return .{
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

fn ensureRequests(context: *anyopaque, count: u64) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .ensure_requests = count });
    if (capture.request_failure) |failure| {
        return failure;
    }
}

fn availableDeliveries(context: *anyopaque) usize {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.available_deliveries);

    return capture.available;
}

fn attachmentPending(context: *anyopaque, pane_id: source_namespace.schema.PaneId) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .attachment_pending = pane_id });

    return capture.pending_pane == pane_id;
}

fn append(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
