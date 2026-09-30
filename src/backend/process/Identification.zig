const core = @import("telar-core");
const process = @import("process.zig");
const SessionHost = @import("../agent/SessionHost.zig").SessionHost;
const Identification = @This();

provider: core.AgentProvider = .unknown,
name: [core.max_foreground_name_bytes]u8 = @splat(0),
name_len: u8 = 0,
/// Where the agent's interactive session, and so its hooks, runs.
session_host: SessionHost = .unknown,

pub fn init(table: *const core.Table, provider: core.AgentProvider, command: []const u8) Identification {
    var result: Identification = .{ .provider = provider };
    const value = process.applicationName(table, provider, command);
    @memcpy(result.name[0..value.len], value);
    result.name_len = @intCast(value.len);
    return result;
}

pub fn slice(self: *const Identification) []const u8 {
    return self.name[0..self.name_len];
}
