const PasteMarkerCommand = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_input.zig");
target: client_model.PaneInputTarget,
marker: source_namespace.PasteMarker,
