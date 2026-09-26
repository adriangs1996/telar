const exchangecapture = @import("exchangecapture");
const Protocol = @import("../Protocol.zig").Protocol;
const Key = exchangecapture.Key;
const buffer_support = exchangecapture.buffer_support;
const StartOptions = @This();

protocol: Protocol,
key: Key,
side: buffer_support.Side,
host: []const u8,
started_at_ms: i64,
