const model_data = @import("model");
const pane_input = @import("pane_input.zig");
const PasteMarkerCommand = @This();

target: model_data.PaneInputTarget,
marker: pane_input.PasteMarker,
