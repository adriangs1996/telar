const StartOptions = @This();
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const source_namespace = @import("root.zig");
credential: identity.Credential,
dialect: middleware.ApiDialect,
protocol: middleware.Protocol,
key: source_namespace.Key,
side: source_namespace.Side,
host: []const u8,
started_at_ms: i64,
