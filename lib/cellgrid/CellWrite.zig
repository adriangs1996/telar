const Style = @import("Style.zig");
const CellWrite = @This();

text: []const u8,
width: u8 = 1,
style: Style = .{},
