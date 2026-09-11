const ModelType = @import("../../model/Model.zig");
const HostCapabilitiesEffects = @import("HostCapabilitiesEffects.zig");
const HostCommitType = @import("../../model/HostCommit.zig");
const std = @import("std");
const EffectsCapture = @This();

model: *const ModelType,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) HostCapabilitiesEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, commit: HostCommitType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    const capabilities = commit.capabilities.?;
    capture.calls += 1;
    capture.observed_commit = std.meta.eql(
        capture.model.hostCapabilities(),
        capabilities.current,
    ) and capture.model.version().host_capabilities ==
        capabilities.host_capabilities_revision;

    if (capture.fail) {
        return error.HostCapabilityEffectsFailed;
    }
}
