const proxy = @import("proxy.zig");
const AuthorityTarget = @This();

backend: proxy.TrustBackend,
certificate: []const u8,
