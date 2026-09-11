const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const workspace_handoff_preparation = @import("workspace_handoff_preparation.zig");
const PrepareWorkspaceHandoffHandler = @import("PrepareWorkspaceHandoffHandler.zig");
const Capture = @This();

model: *ModelType,
pending_pane: ?PaneIdType,
available: usize,
request_failure: ?anyerror = null,
events: [5]workspace_handoff_preparation.Event = undefined,
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

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.queries_observed_unchanged = capture.queries_observed_unchanged and
        capture.model.panePasteActive() and
        capture.model.reportedPaneFocus() != null and
        capture.model.workspace.findPane(pane_id) != null;
    capture.append(.{ .attachment_pending = pane_id });

    return capture.pending_pane == pane_id;
}

fn append(capture: *Capture, event: workspace_handoff_preparation.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const workspace_handoff_preparation.Event {
    return capture.events[0..capture.event_count];
}
