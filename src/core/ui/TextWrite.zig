const Point = @import("Point.zig");
const Style = @import("Style.zig");
const TextWrite = @This();

point: Point,
text: []const u8,
style: Style = .{},
