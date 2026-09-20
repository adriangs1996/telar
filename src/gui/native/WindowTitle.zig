const client = @import("telar-client");

pub const WindowTitle = extern struct {
    bytes: [client.max_title_bytes + 1]u8 = @splat(0),
    len: u32 = 0,
};
