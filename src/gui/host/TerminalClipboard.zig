//! Identity of an asynchronous terminal paste and progress of its delivery.
const PaneId = @import("telar-core").PaneId;

request_id: u64 = 0,
pane_id: ?PaneId = null,
generation: u64 = 0,
offset: ?usize = null,
