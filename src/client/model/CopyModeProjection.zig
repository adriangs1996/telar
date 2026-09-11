const PaneIdType = @import("telar-core").PaneId;
const ViewType = @import("../input/CopyModeView.zig");
const CopyModeProjection = @This();

pane_id: PaneIdType,
view: ViewType,
