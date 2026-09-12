const IconType = @import("../layout/icons.zig").Icon;
const StyleType = @import("../bars/Style.zig");
const ParsedBarSegment = @This();

text: []const u8,
icon: ?IconType,
style: StyleType,
