const PointType = @import("Point.zig");
const StyleType = @import("Style.zig");
const TextWrite = @This();

point: PointType,
text: []const u8,
style: StyleType = .{},
