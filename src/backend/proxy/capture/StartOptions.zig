const exchangecapture = @import("exchangecapture");
const Credential = @import("../Credential.zig");
const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");
const Key = exchangecapture.Key;
const buffer_support = exchangecapture.buffer_support;
const StartOptions = @This();

credential: Credential,
dialect: types.ApiDialect,
protocol: middleware.Protocol,
key: Key,
side: buffer_support.Side,
host: []const u8,
started_at_ms: i64,
