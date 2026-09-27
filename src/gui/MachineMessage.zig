//! A client event for one of the window's other machines: the slot of its
//! client in the window's array, and the event. The window's own client
//! keeps the plain `client` event.
const client = @import("telar-client");
const MachineMessage = @This();

slot: u8,
message: client.Message,
