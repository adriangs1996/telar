const PointType = @import("Point.zig");
const StyleType = @import("Style.zig");
const TruncatedText = @This();

point: PointType,
text: []const u8,
max_width: u16,
style: StyleType = .{},
