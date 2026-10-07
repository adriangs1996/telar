//! A client event for one of the window's machines: the slot of its client
//! in the window's array, and the event. The window's own client is
//! `Machines.local_slot`.
const client = @import("telar-client");

slot: u8,
message: client.Message,
