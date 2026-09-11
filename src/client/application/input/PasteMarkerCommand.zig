const types = @import("../../model/types.zig");
const pane_input = @import("pane_input.zig");
const PasteMarkerCommand = @This();

target: types.PaneInputTarget,
marker: pane_input.PasteMarker,
