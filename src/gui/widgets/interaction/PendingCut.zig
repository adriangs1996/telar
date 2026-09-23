//! A cut removes its original selection only after the host stored it and
//! the editor still has the same revision. Host failure cannot lose text.
const Id = @import("Id.zig");

request_id: u64,
owner: Id,
range: [2]u32,
revision: u64,
