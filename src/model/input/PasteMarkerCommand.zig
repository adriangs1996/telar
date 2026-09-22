const PaneInputTarget = @import("../types/PaneInputTarget.zig").PaneInputTarget;
const PanePasteMarker = @import("../types/PanePasteMarker.zig").PanePasteMarker;
const PasteMarkerCommand = @This();

target: PaneInputTarget,
marker: PanePasteMarker,
