const ParsedBarSegment = @This();
const icons = @import("../ui/root.zig").icons;
const bars = @import("../bars/root.zig");
text: []const u8,
icon: ?icons.Icon,
style: bars.Style,
