//! A machine one window reaches over SSH: its destination, and the window
//! slot that keeps this window's forwarded socket apart from another
//! window's on the same machine.
const RemoteMachine = @This();

destination: []const u8,
window_slot: u8 = 0,
