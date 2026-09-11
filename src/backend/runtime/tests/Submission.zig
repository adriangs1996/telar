const QueryType = @import("../../history/Query.zig");
const ServicePortType = @import("../application/queries/ServicePort.zig");
const Submission = @This();

query: ?QueryType = null,

pub fn port(submission: *Submission) ServicePortType {
    return .{ .context = submission, .submit_fn = submit };
}

fn submit(context: *anyopaque, query: QueryType) bool {
    const submission: *Submission = @ptrCast(@alignCast(context));
    submission.query = query;
    return true;
}
