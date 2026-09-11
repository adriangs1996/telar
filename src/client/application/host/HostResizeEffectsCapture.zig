const ModelType = @import("../../model/Model.zig");
const HostCommitType = @import("../../model/HostCommit.zig");
const HostResizeEffects = @import("HostResizeEffects.zig");
const std = @import("std");
const EffectsCapture = @This();

model: *const ModelType,
calls: usize = 0,
observed_commit: bool = false,
commit: ?HostCommitType = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) HostResizeEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, commit: HostCommitType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.commit = commit;
    const resize_observed = if (commit.resize) |resize|
        std.meta.eql(capture.model.hostSize(), resize.current) and
            capture.model.version().host == resize.host_revision
    else
        true;
    const capabilities_observed = if (commit.capabilities) |capabilities|
        std.meta.eql(capture.model.hostCapabilities(), capabilities.current) and
            capture.model.version().host_capabilities ==
                capabilities.host_capabilities_revision
    else
        true;
    capture.observed_commit = resize_observed and capabilities_observed;

    if (capture.fail) {
        return error.HostResizeEffectsFailed;
    }
}
