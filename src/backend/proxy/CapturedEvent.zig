const CapturedEvent = @This();
const source_namespace = @import("sse.zig");
name: [source_namespace.max_event_name_bytes]u8 = undefined,
name_len: usize = 0,
data: [source_namespace.max_data_bytes]u8 = undefined,
data_len: usize = 0,
truncated: bool = false,

pub fn nameSlice(event: *const CapturedEvent) []const u8 {
    return event.name[0..event.name_len];
}

pub fn dataSlice(event: *const CapturedEvent) []const u8 {
    return event.data[0..event.data_len];
}
