const Input = @This();
const ui = @import("../ui/root.zig");
const source_namespace = @import("tab_bar.zig");
const bars = @import("../bars/root.zig");
area: ui.Rect,
tabs: ?*const source_namespace.tabs_mod.Model,
model: *const source_namespace.multiplexer.Model,
alignment: bars.Alignment = .right,
animation_frame: u8 = 0,
