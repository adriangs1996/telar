const core = @import("telar-core");
pub const Operation = union(enum) {
    query: core.QueryChangeReview,
    command: core.ChangeReviewCommand,
    sample: core.ReportChangeReviewSample,
};
