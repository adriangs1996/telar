//! Identity of an asynchronous terminal paste and progress of its delivery.
const core = @import("telar-core");

request_id: u64 = 0,
pane_id: ?core.PaneId = null,
generation: u64 = 0,
offset: ?usize = null,
