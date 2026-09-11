const PaneRange = @This();
const source_namespace = @import("multiplexer.zig");
screen: *source_namespace.term.Screen,
composed: *source_namespace.ui.Buffer,
pane: *const source_namespace.Pane,
destination_x: u16,
destination_y: u16,
source_y: u16,
start: u16,
end: u16,
copy: ?source_namespace.copy_mode.View,
