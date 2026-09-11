const AuthorityTarget = @This();
const source_namespace = @import("proxy.zig");
backend: source_namespace.TrustBackend,
certificate: []const u8,
