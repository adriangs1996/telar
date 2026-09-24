const exchangecapture = @import("exchangecapture");
const buffer_support = exchangecapture.buffer_support;
const Half = @This();

head: []const u8,
body: []const u8,
encoding: []const u8,
decoded: bool,
head_truncated: bool,
body_truncated: bool,
status_code: u16,
outcome: buffer_support.Outcome,
finished_at_ms: i64,
