const model = @import("../../history/model.zig");
const std = @import("std");
/// One-shot integration seam for post-spawn launch recovery.
const LaunchTestFault = @This();

phase: model.LaunchPhase,
claimed: std.atomic.Value(bool) = .init(false),

pub fn inject(fault: *LaunchTestFault, phase: model.LaunchPhase) !void {
    if (fault.phase != phase) {
        return;
    }
    if (fault.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return;
    }
    return error.InjectedLaunchFailure;
}
