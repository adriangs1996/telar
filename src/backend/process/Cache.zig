const core = @import("telar-core");
const process = @import("process.zig");
const SessionHost = @import("../agent/SessionHost.zig").SessionHost;
const Cache = @This();

process_group_id: ?u32 = null,
provider: core.AgentProvider = .unknown,
attempts: u8 = 0,
foreground_name: [core.max_foreground_name_bytes]u8 = @splat(0),
foreground_name_len: u8 = 0,
/// Where the identified agent's interactive session, and so its hooks,
/// runs.
session_host: SessionHost = .unknown,
/// The group member the agent was identified in.
agent_pid: ?u32 = null,
/// telar's hooks for the agent are installed, as read when a session that
/// may run on a shared server was identified.
hooks_installed: bool = false,
/// Identify the process group again even though it did not change: a
/// process may have replaced itself with another agent.
recheck: bool = false,

pub fn init(executable: []const u8) Cache {
    var cache: Cache = .{};
    cache.setName(process.boundedCommandName(executable));
    return cache;
}

pub fn name(self: *const Cache) []const u8 {
    return self.foreground_name[0..self.foreground_name_len];
}

pub fn setName(self: *Cache, value: []const u8) void {
    const source = if (value.len == 0) "process" else value;
    const len = @min(source.len, self.foreground_name.len);
    @memcpy(self.foreground_name[0..len], source[0..len]);
    self.foreground_name_len = @intCast(len);
}
