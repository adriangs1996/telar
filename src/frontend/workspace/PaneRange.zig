const core = @import("telar-core");
const client = @import("telar-client");
const data = @import("model");
const ScreenType = @import("../presentation/Screen.zig");
const PaneRange = @This();

screen: *ScreenType,
composed: *core.Buffer,
pane: *const client.Pane,
destination_x: u16,
destination_y: u16,
source_y: u16,
start: u16,
end: u16,
copy: ?data.CopyModeView,
