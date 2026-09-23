const data = @import("model");
const client = @import("telar-client");
const std = @import("std");
const host_negotiation = @import("host_negotiation.zig");
const HostNegotiation = @This();

zlib_support: data.EnvironmentSupport = .unknown,
deadline_ns: ?u64 = null,
received: std.EnumSet(host_negotiation.Color) = .initEmpty(),
initial_settled: bool = false,
timer: client.Scheduler = .{},

/// Example: `if (state.begin(now_ns)) try writer.writeAll(color_query);`.
pub fn begin(self: *HostNegotiation, now_ns: u64) bool {
    if (self.deadline_ns != null) {
        return false;
    }

    self.deadline_ns = now_ns +| host_negotiation.timeout_ns;
    self.received = .initEmpty();
    return true;
}

/// Example: `if (!state.accept(.foreground, now_ns)) return;`.
pub fn accept(self: *HostNegotiation, color: host_negotiation.Color, now_ns: u64) bool {
    const deadline = self.deadline_ns orelse return false;
    if (now_ns >= deadline or self.received.contains(color)) {
        return false;
    }

    self.received.insert(color);
    if (self.received.count() == 2) {
        self.initial_settled = true;
    }

    return true;
}

/// Example: `if (state.expire(now_ns)) settleUnansweredCapabilities();`.
pub fn expire(self: *HostNegotiation, now_ns: u64) bool {
    const deadline = self.deadline_ns orelse return false;
    if (now_ns < deadline) {
        return false;
    }

    self.deadline_ns = null;
    self.initial_settled = true;
    return true;
}
