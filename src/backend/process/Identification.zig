const Identification = @This();
const source_namespace = @import("root.zig");
provider: source_namespace.schema.AgentProvider = .unknown,
name: [source_namespace.schema.max_foreground_name_bytes]u8 = @splat(0),
name_len: u8 = 0,

pub fn init(table: *const source_namespace.Table, provider: source_namespace.schema.AgentProvider, command: []const u8) Identification {
    var result: Identification = .{ .provider = provider };
    const value = source_namespace.applicationName(table, provider, command);
    @memcpy(result.name[0..value.len], value);
    result.name_len = @intCast(value.len);
    return result;
}

pub fn slice(result: *const Identification) []const u8 {
    return result.name[0..result.name_len];
}
