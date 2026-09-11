const QueryType = @import("../../../history/Query.zig");
const ServicePort = @import("ServicePort.zig");
const SubmissionCapture = @This();

accepted: bool = true,
calls: usize = 0,
query: QueryType = undefined,

pub fn port(capture: *SubmissionCapture) ServicePort {
    return .{ .context = capture, .submit_fn = submit };
}

fn submit(context: *anyopaque, query: QueryType) bool {
    const capture: *SubmissionCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.query = query;
    return capture.accepted;
}
