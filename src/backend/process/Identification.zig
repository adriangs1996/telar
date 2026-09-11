const AgentProviderType = @import("telar-core").AgentProvider;
const max_foreground_name_bytes_module = @import("telar-core").max_foreground_name_bytes;
const TableType = @import("telar-core").Table;
const process = @import("process.zig");
const Identification = @This();

provider: AgentProviderType = .unknown,
name: [max_foreground_name_bytes_module]u8 = @splat(0),
name_len: u8 = 0,

pub fn init(table: *const TableType, provider: AgentProviderType, command: []const u8) Identification {
    var result: Identification = .{ .provider = provider };
    const value = process.applicationName(table, provider, command);
    @memcpy(result.name[0..value.len], value);
    result.name_len = @intCast(value.len);
    return result;
}

pub fn slice(result: *const Identification) []const u8 {
    return result.name[0..result.name_len];
}
