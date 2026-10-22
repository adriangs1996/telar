//! A client holds a tab while it shows something there besides terminals,
//! such as another application's windows: a held tab outlives its last pane
//! until no client holds it, or the clients holding it disconnect.
const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");

request_id: id.RequestId,
location: TabLocation,
held: bool,
