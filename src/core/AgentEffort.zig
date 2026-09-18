const std = @import("std");
const limits = @import("agent_thread.zig");
const AgentEffort = @This();

id: [limits.max_effort_bytes]u8 = @splat(0),
id_len: u8 = 0,

/// Owns a provider-advertised effort identifier. Example: `const effort = try AgentEffort.init("high");`
pub fn init(value: []const u8) !AgentEffort {
    if (value.len == 0 or value.len > limits.max_effort_bytes or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidAgentEffort;
    }

    var effort: AgentEffort = .{ .id_len = @intCast(value.len) };
    @memcpy(effort.id[0..value.len], value);
    return effort;
}

/// Example: `drawLabel(effort.idSlice());`
pub fn idSlice(effort: *const AgentEffort) []const u8 {
    return effort.id[0..effort.id_len];
}

/// Example: `if (effort.eql(other)) return;`
pub fn eql(effort: AgentEffort, other: AgentEffort) bool {
    return std.mem.eql(u8, effort.idSlice(), other.idSlice());
}
