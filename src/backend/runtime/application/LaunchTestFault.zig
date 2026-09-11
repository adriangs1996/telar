/// One-shot integration seam for post-spawn launch recovery.
const LaunchTestFault = @This();
const history = @import("../../history/root.zig");
const std = @import("std");
phase: history.LaunchPhase,
claimed: std.atomic.Value(bool) = .init(false),

pub fn inject(fault: *LaunchTestFault, phase: history.LaunchPhase) !void {
    if (fault.phase != phase) {
        return;
    }
    if (fault.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return;
    }
    return error.InjectedLaunchFailure;
}
