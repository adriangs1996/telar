const HeaderBlock = @This();
const HeaderField = @import("HeaderField.zig");
stream_id: u32,
fields: []const HeaderField,
