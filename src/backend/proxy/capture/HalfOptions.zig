const std = @import("std");
const Quota = @import("Quota.zig");
const Config = @import("Config.zig");
const CredentialType = @import("../Credential.zig");
const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");
const Key = @import("Key.zig");
const buffer_support = @import("buffer_support.zig");
const HalfOptions = @This();

gpa: std.mem.Allocator,
quota: *Quota,
config: Config,
credential: CredentialType,
dialect: types.ApiDialect,
protocol: middleware.Protocol,
key: Key,
side: buffer_support.Side,
host: []const u8,
started_at_ms: i64,
