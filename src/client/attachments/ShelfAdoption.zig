//! What adopting one capture did to the shelf: whether the pane layout must
//! change, and the limit the previews evicted to make room reached, which
//! the client flow reports.
const core = @import("telar-core");

layout_changed: bool,
evicted: ?core.LimitReach = null,
