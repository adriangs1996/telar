const Rejection = @This();
const source_namespace = @import("connect_authentication.zig");
reason: source_namespace.RejectionReason,
response: []const u8,
metric: ?source_namespace.RejectionMetric,
