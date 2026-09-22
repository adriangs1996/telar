const core = @import("telar-core");
/// Bytes one pane may send again once the client released retained images.
const Credit = @This();

pane_id: core.PaneId,
bytes: usize,
