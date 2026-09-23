//! An asynchronous read may replace only the selection and revision that
//! requested it. A changed draft or focus cannot inherit the returned bytes.
const Id = @import("Id.zig");

request_id: u64,
owner: Id,
range: [2]u32,
revision: u64,
