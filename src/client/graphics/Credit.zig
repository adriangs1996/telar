const PaneIdType = @import("telar-core").PaneId;
/// Bytes one pane may send again once the client released retained images.
const Credit = @This();

pane_id: PaneIdType,
bytes: usize,
