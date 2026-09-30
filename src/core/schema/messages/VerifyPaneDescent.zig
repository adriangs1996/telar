const id = @import("../id.zig");
/// Asks the runtime to confirm that the process at the other end of this
/// connection descends from one exact pane generation: that its chain of
/// parent processes reaches the pane's root process. The runtime reads the
/// sender's process from the socket and walks the chain itself; a confirmed
/// connection may then report for that pane in the name of its agent.
const VerifyPaneDescent = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
