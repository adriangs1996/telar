const CredentialType = @import("../Credential.zig");
const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");
const KeyType = @import("Key.zig");
const buffer_support = @import("buffer_support.zig");
const StartOptions = @This();

credential: CredentialType,
dialect: types.ApiDialect,
protocol: middleware.Protocol,
key: KeyType,
side: buffer_support.Side,
host: []const u8,
started_at_ms: i64,
