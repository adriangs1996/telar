const Submission = @This();
const history_mod = @import("../../history/root.zig");
const history_query = @import("../application/queries/history.zig");
query: ?history_mod.Query = null,

pub fn port(submission: *Submission) history_query.ServicePort {
    return .{ .context = submission, .submit_fn = submit };
}

fn submit(context: *anyopaque, query: history_mod.Query) bool {
    const submission: *Submission = @ptrCast(@alignCast(context));
    submission.query = query;
    return true;
}
