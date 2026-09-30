const core = @import("telar-core");
const process = @import("process.zig");
const Identification = @This();

provider: core.AgentProvider = .unknown,
name: [core.max_foreground_name_bytes]u8 = @splat(0),
name_len: u8 = 0,
/// The agent runs its session, and its hooks, in a shared server outside
/// the pane.
shared_server: bool = false,

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
