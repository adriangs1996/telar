const ScreenType = @import("../presentation/Screen.zig");
const BufferType = @import("telar-core").Buffer;
const PaneType = @import("telar-client").Pane;
const ViewType = @import("telar-client").CopyModeView;
const PaneRange = @This();

screen: *ScreenType,
composed: *BufferType,
pane: *const PaneType,
destination_x: u16,
destination_y: u16,
source_y: u16,
start: u16,
end: u16,
copy: ?ViewType,
