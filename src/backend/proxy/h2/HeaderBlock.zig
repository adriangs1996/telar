const HeaderField = @import("HeaderField.zig");
const HeaderBlock = @This();

stream_id: u32,
fields: []const HeaderField,
