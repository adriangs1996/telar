const core = @import("telar-core");
const Handler = @import("../../application/commands/ChangeReviewHandler.zig");
const Delivery = @import("../../delivery/Delivery.zig");
const PendingFailure = @import("../../delivery/PendingFailure.zig");

handler: *Handler,
delivery: *Delivery,

/// Keeps expected protocol failures correlated while the application owns admission.
/// Example: `try controller.handle(command);`.
pub fn handle(self: *@This(), value: anytype) !void {
    self.handler.execute(value) catch |err| {
        try self.delivery.responses.push(.{ .request_failed = failure(value.request_id, err) });
    };
}

pub fn failure(request_id: core.RequestId, err: anyerror) PendingFailure {
    return .{ .request_id = request_id, .code = switch (err) {
        error.PaneNotFound => .pane_not_found,
        error.PaneExited => .pane_exited,
        error.AgentBusy => .agent_blocked,
        error.ReviewBusy, error.ReviewCapacity, error.OutOfMemory, error.WriteFailed => .resource_limit,
        else => .invalid_request,
    }, .message = switch (err) {
        error.PaneNotFound => "review pane no longer exists",
        error.PaneExited => "review pane is closing",
        error.AgentNotReady, error.InvalidReviewOwner => "review does not belong to the current agent session",
        error.StaleReview => "review changed in another client; refresh before saving",
        error.ReviewAlreadySubmitted => "submitted review comments are immutable",
        error.ReviewBusy => "another review operation is pending; retry shortly",
        error.AgentBusy => "review retained; agent is busy, retry Send review when ready",
        error.EditionNotFound => "review edition is unavailable",
        error.EmptyComment => "write a comment before saving it",
        error.NoSavedComments => "save at least one comment before sending the review",
        error.InvalidReviewAnchor => "comment range is outside the immutable edition",
        error.InvalidPatch => "edit has no complete supported text diff; it was not retained",
        error.MissingReviewBaseline => "no matching before snapshot; edit was not attributed",
        error.ReviewCapacity, error.WriteFailed => "review exceeds its bounded storage or feedback limit",
        error.InvalidReviewStorage => "review storage failed validation; existing file was preserved",
        error.ReviewUnavailable => "review service is unavailable",
        else => "review operation failed; retry without discarding local comments",
    } };
}
