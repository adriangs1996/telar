const Input = @This();
const ui = @import("../ui/root.zig");
const source_namespace = @import("tab_rename.zig");
area: ui.Rect,
field: *source_namespace.Field,
kind: source_namespace.Kind,
