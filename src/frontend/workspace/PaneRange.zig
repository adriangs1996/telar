const core = @import("telar-core");
const client = @import("telar-client");
const data = @import("model");
const Screen = @import("../presentation/Screen.zig");
const PaneRange = @This();

screen: *Screen,
composed: *core.Buffer,
pane: *const data.Pane,
destination_x: u16,
destination_y: u16,
source_y: u16,
start: u16,
end: u16,
copy: ?data.CopyModeView,
