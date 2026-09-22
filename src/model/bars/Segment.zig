const ui_icons = @import("../layout/icons.zig");
const Style = @import("Style.zig");
const Segment = @This();

text_offset: u16 = 0,
text_len: u16 = 0,
icon: ?ui_icons.Icon = null,
style: Style = .{},
