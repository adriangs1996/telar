const ui_icons = @import("../layout/icons.zig");
const Style = @import("Style.zig");

text: []const u8,
icon: ?ui_icons.Icon = null,
style: Style = .{},
