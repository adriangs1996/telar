const StyleType = @import("Style.zig");
const RightAlignedText = @This();

y: u16,
text: []const u8,
style: StyleType = .{},
