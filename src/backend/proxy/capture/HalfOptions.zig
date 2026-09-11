const HalfOptions = @This();
const std = @import("std");
const Quota = @import("Quota.zig");
const Config = @import("Config.zig");
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const Key = @import("Key.zig");
const source_namespace = @import("buffer_support.zig");
gpa: std.mem.Allocator,
quota: *Quota,
config: Config,
credential: identity.Credential,
dialect: middleware.ApiDialect,
protocol: middleware.Protocol,
key: Key,
side: source_namespace.Side,
host: []const u8,
started_at_ms: i64,
