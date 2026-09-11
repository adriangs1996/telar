const Half = @This();
const proxy = @import("../proxy/root.zig");
head: []const u8,
body: []const u8,
encoding: []const u8,
decoded: bool,
head_truncated: bool,
body_truncated: bool,
status_code: u16,
outcome: proxy.CaptureOutcome,
finished_at_ms: i64,
