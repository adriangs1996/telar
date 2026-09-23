const Point = @import("Point.zig");
const Style = @import("Style.zig");
const TruncatedText = @This();

point: Point,
text: []const u8,
max_width: u16,
style: Style = .{},
