const DrawContext = @This();
const State = @import("State.zig");
const source_namespace = @import("sidebar.zig");
state: *State,
buffer: *source_namespace.ui.Buffer,
area: source_namespace.ui.Rect,
