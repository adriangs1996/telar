const Credential = @import("../Credential.zig");
const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");
const Key = @import("Key.zig");
const buffer_support = @import("buffer_support.zig");
const StartOptions = @This();

credential: Credential,
dialect: types.ApiDialect,
protocol: middleware.Protocol,
key: Key,
side: buffer_support.Side,
host: []const u8,
started_at_ms: i64,
