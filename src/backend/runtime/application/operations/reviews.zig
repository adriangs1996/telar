//! Runtime reviews operations, reached from requests.dispatch.

const core = @import("telar-core");
const Job = @import("../../../change_review/Job.zig");
const review_owner = @import("../change_review_owner.zig");
const PendingFailureType = @import("../../delivery/PendingFailure.zig");
const std = @import("std");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try reviews.routeQueryChangeReview(request, message);`.
pub fn routeQueryChangeReview(request: *RequestContext, message: core.QueryChangeReview) !void {
    admitReview(request, message) catch |err| {
        try request.session.delivery.responses.push(.{ .request_failed = reviewFailure(message.request_id, err) });
    };
}

/// Example: `try reviews.routeChangeReviewCommand(request, message);`.
pub fn routeChangeReviewCommand(request: *RequestContext, message: core.ChangeReviewCommand) !void {
    admitReview(request, message) catch |err| {
        try request.session.delivery.responses.push(.{ .request_failed = reviewFailure(message.request_id, err) });
    };
}

/// Example: `try reviews.routeReportChangeReviewSample(request, message);`.
pub fn routeReportChangeReviewSample(request: *RequestContext, message: core.ReportChangeReviewSample) !void {
    admitReview(request, message) catch |err| {
        try request.session.delivery.responses.push(.{ .request_failed = reviewFailure(message.request_id, err) });
    };
}

fn admitReview(request: *RequestContext, value: anytype) !void {
    const model = request.model;
    const client = request.session;
    const context = try review_owner.resolve(model, .{ .id = value.pane_id, .generation = value.pane_generation });
    const T = @TypeOf(value);
    if ((T != core.QueryChangeReview or value.session.len != 0) and !std.mem.eql(u8, value.session, context.sessionSlice())) {
        return error.InvalidReviewOwner;
    }
    if (T == core.ReportChangeReviewSample or T == core.ChangeReviewCommand) {
        const scoped = if (T == core.ReportChangeReviewSample) true else value.action == .feedback or value.action == .ack_feedback;
        if (scoped and value.provider != context.provider) {
            return error.InvalidReviewOwner;
        }
    }
    const service = model.review_service orelse return error.ReviewUnavailable;
    if (client.delivery.responses.hasChangeReview()) {
        return error.ReviewBusy;
    }
    const slot = try model.review_jobs.available(client.key);
    const job = &model.review_jobs.storage[slot];
    job.* = .{ .service = service, .context = context, .client = client.key, .request_id = value.request_id, .wire_len = 0 };
    const wire = if (T == core.QueryChangeReview) try core.encodeQueryChangeReview(&job.wire, value) else if (T == core.ChangeReviewCommand) try core.encodeChangeReviewCommand(&job.wire, value) else try core.encodeReportChangeReviewSample(&job.wire, value);
    job.wire_len = @intCast(wire.len);
    model.review_jobs.items[slot] = job;
    errdefer model.review_jobs.items[slot] = null;
    try model.select.concurrent(.change_review_completed, Job.run, .{ job, model.io });
}

/// Example: `reviews.reviewFailure(request_id, err);`.
pub fn reviewFailure(request_id: core.RequestId, err: anyerror) PendingFailureType {
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
