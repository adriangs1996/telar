const PaneInputTarget = @import("PaneInputTarget.zig").PaneInputTarget;
const PasteMarkerCommand = @This();

target: PaneInputTarget,
marker: PanePasteMarker,

const PanePasteMarker = enum {
    start,
    finish,
};
