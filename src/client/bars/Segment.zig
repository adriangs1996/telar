const Segment = @This();
const ui_icons = @import("../layout/root.zig").icons;
const Style = @import("Style.zig");
text_offset: u16 = 0,
text_len: u16 = 0,
icon: ?ui_icons.Icon = null,
style: Style = .{},
