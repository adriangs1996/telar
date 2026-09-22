const icons = @import("../layout/icons.zig");
const StyleType = @import("../bars/Style.zig");
const ParsedBarSegment = @This();

text: []const u8,
icon: ?icons.Icon,
style: StyleType,
