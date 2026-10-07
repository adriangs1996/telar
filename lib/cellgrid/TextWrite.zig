const Point = @import("Point.zig");
const Style = @import("Style.zig");

point: Point,
text: []const u8,
style: Style = .{},
