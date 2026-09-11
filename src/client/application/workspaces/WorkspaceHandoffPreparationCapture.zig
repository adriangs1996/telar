const Capture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_handoff_preparation.zig");
const PrepareWorkspaceHandoffHandler = @import("PrepareWorkspaceHandoffHandler.zig");
model: *client_model.Model,
pending_pane: ?source_namespace.schema.PaneId,
available: usize,
request_failure: ?anyerror = null,
events: [5]source_namespace.Event = undefined,
event_count: usize = 0,
queries_observed_unchanged: bool = true,

pub fn handler(capture: *Capture) PrepareWorkspaceHandoffHandler {
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
    capture.queries_observed_unchanged = capture.queries_observed_unchanged and
        capture.model.panePasteActive() and
        capture.model.reportedPaneFocus() != null and
        capture.model.workspace.findPane(pane_id) != null;
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
