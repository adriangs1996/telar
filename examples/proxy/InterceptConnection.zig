const InterceptConnection = @This();
const source_namespace = @import("tls.zig");
host: []const u8,
child: source_namespace.net.Stream,
origin: source_namespace.net.Stream,
