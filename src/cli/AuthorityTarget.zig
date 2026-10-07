const proxy = @import("proxy.zig");

backend: proxy.TrustBackend,
certificate: []const u8,
