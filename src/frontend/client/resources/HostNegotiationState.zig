const State = @This();
const std = @import("std");
const source_namespace = @import("host_negotiation.zig");
const deadline_timer = @import("telar-client").resources.deadline_timer;
zlib_support: @import("telar-client").environment.Support = .unknown,
deadline_ns: ?u64 = null,
received: std.EnumSet(source_namespace.Color) = .initEmpty(),
initial_settled: bool = false,
timer: deadline_timer.Scheduler = .{},

/// Example: `if (state.begin(now_ns)) try writer.writeAll(color_query);`.
pub fn begin(state: *State, now_ns: u64) bool {
    if (state.deadline_ns != null) {
        return false;
    }

    state.deadline_ns = now_ns +| source_namespace.timeout_ns;
    state.received = .initEmpty();
    return true;
}

/// Example: `if (!state.accept(.foreground, now_ns)) return;`.
pub fn accept(state: *State, color: source_namespace.Color, now_ns: u64) bool {
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
