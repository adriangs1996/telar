const core = @import("telar-core");
/// Bytes one pane may send again once the client released retained images.
pane_id: core.PaneId,
bytes: usize,
