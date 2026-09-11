const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("HostResizeEffects.zig");
const std = @import("std");
model: *const client_model.Model,
calls: usize = 0,
observed_commit: bool = false,
commit: ?client_model.HostCommit = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) Effects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, commit: client_model.HostCommit) !void {
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
