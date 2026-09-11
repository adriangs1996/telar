const Cache = @This();
const source_namespace = @import("root.zig");
process_group_id: ?u32 = null,
provider: source_namespace.schema.AgentProvider = .unknown,
attempts: u8 = 0,
foreground_name: [source_namespace.schema.max_foreground_name_bytes]u8 = @splat(0),
foreground_name_len: u8 = 0,

pub fn init(executable: []const u8) Cache {
    var cache: Cache = .{};
    cache.setName(source_namespace.boundedCommandName(executable));
    return cache;
}

pub fn name(cache: *const Cache) []const u8 {
    return cache.foreground_name[0..cache.foreground_name_len];
}

pub fn setName(cache: *Cache, value: []const u8) void {
    const source = if (value.len == 0) "process" else value;
    const len = @min(source.len, cache.foreground_name.len);
    @memcpy(cache.foreground_name[0..len], source[0..len]);
    cache.foreground_name_len = @intCast(len);
}
