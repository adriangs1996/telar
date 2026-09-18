//! An asynchronous read may replace only the selection and revision that
//! requested it. A changed draft or focus cannot inherit the returned bytes.
request_id: u64,
owner: @import("Id.zig"),
range: [2]u32,
revision: u64,
