pub fn Type(comptime max_bytes: usize) type {
    return struct {
        const Self = @This();

        bytes: [max_bytes]u8 = undefined,
        len: u16,

        pub fn init(name: []const u8) !Self {
            if (name.len == 0 or name.len > max_bytes) {
                return error.InvalidWorkspaceName;
            }

            var owned: Self = .{ .len = @intCast(name.len) };
            @memcpy(owned.bytes[0..name.len], name);
            return owned;
        }

        pub fn slice(name: *const Self) []const u8 {
            return name.bytes[0..name.len];
        }
    };
}
