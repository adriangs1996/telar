const PaneIdType = @import("telar-core").PaneId;
const tab_close_preparation = @import("tab_close_preparation.zig");
const PrepareTabCloseHandler = @import("PrepareTabCloseHandler.zig");
const Capture = @This();

pending_pane: ?PaneIdType,
available: usize,
request_failure: ?anyerror = null,
events: [4]tab_close_preparation.Event = undefined,
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

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .attachment_pending = pane_id });

    return capture.pending_pane == pane_id;
}

fn append(capture: *Capture, event: tab_close_preparation.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const tab_close_preparation.Event {
    return capture.events[0..capture.event_count];
}
