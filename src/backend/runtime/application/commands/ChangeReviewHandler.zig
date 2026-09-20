const std = @import("std");
const core = @import("telar-core");
const Application = @import("../Application.zig");
const Session = @import("../../client/Session.zig");
const Job = @import("../../../change_review/Job.zig");
const review_owner = @import("../change_review_owner.zig");

application: *Application,
client: *Session,

/// Admits copied commands after resolving the exact pane and conversation owner.
/// Example: `try handler.execute(command);`.
pub fn execute(self: *@This(), value: anytype) !void {
    const application = self.application;
    const client = self.client;
    const context = try review_owner.resolve(application, .{ .id = value.pane_id, .generation = value.pane_generation });
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
    const service = application.review_service orelse return error.ReviewUnavailable;
    if (client.delivery.responses.hasChangeReview()) {
        return error.ReviewBusy;
    }
    const slot = try application.review_jobs.available(client.key);
    const job = &application.review_jobs.storage[slot];
    job.* = .{ .service = service, .context = context, .client = client.key, .request_id = value.request_id, .wire_len = 0 };
    const wire = if (T == core.QueryChangeReview) try core.encodeQueryChangeReview(&job.wire, value) else if (T == core.ChangeReviewCommand) try core.encodeChangeReviewCommand(&job.wire, value) else try core.encodeReportChangeReviewSample(&job.wire, value);
    job.wire_len = @intCast(wire.len);
    application.review_jobs.items[slot] = job;
    errdefer application.review_jobs.items[slot] = null;
    try application.select.concurrent(.change_review_completed, Job.run, .{ job, application.io });
}
