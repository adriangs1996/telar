const SupportType = @import("telar-client").Support;
const std = @import("std");
const host_negotiation = @import("host_negotiation.zig");
const SchedulerType = @import("telar-client").Scheduler;
const State = @This();

zlib_support: SupportType = .unknown,
deadline_ns: ?u64 = null,
received: std.EnumSet(host_negotiation.Color) = .initEmpty(),
initial_settled: bool = false,
timer: SchedulerType = .{},

/// Example: `if (state.begin(now_ns)) try writer.writeAll(color_query);`.
pub fn begin(state: *State, now_ns: u64) bool {
    if (state.deadline_ns != null) {
        return false;
    }

    state.deadline_ns = now_ns +| host_negotiation.timeout_ns;
    state.received = .initEmpty();
    return true;
}

/// Example: `if (!state.accept(.foreground, now_ns)) return;`.
pub fn accept(state: *State, color: host_negotiation.Color, now_ns: u64) bool {
    const deadline = state.deadline_ns orelse return false;
    if (now_ns >= deadline or state.received.contains(color)) {
        return false;
    }

    state.received.insert(color);
    if (state.received.count() == 2) {
        state.initial_settled = true;
    }

    return true;
}

/// Example: `if (state.expire(now_ns)) settleUnansweredCapabilities();`.
pub fn expire(state: *State, now_ns: u64) bool {
    const deadline = state.deadline_ns orelse return false;
    if (now_ns < deadline) {
        return false;
    }

    state.deadline_ns = null;
    state.initial_settled = true;
    return true;
}
