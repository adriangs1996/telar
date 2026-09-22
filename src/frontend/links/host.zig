//! TUI and GUI use the same bounded host URL worker.
const client = @import("telar-client");
pub const open = client.openHostLink;
