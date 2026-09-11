const SubmissionCapture = @This();
const source_namespace = @import("history.zig");
const ServicePort = @import("ServicePort.zig");
accepted: bool = true,
calls: usize = 0,
query: source_namespace.Query = undefined,

pub fn port(capture: *SubmissionCapture) ServicePort {
    return .{ .context = capture, .submit_fn = submit };
}

fn submit(context: *anyopaque, query: source_namespace.Query) bool {
    const capture: *SubmissionCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.query = query;
    return capture.accepted;
}
