const RectType = @import("telar-core").Rect;
const tab_rename = @import("tab_rename.zig");
const Input = @This();

area: RectType,
field: *tab_rename.Field,
kind: tab_rename.Kind,
