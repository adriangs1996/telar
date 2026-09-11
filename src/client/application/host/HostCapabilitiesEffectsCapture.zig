const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("HostCapabilitiesEffects.zig");
const std = @import("std");
model: *const client_model.Model,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) Effects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, commit: client_model.HostCommit) !void {
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
