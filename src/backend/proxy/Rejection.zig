const connect_authentication = @import("connect_authentication.zig");
const Rejection = @This();

reason: connect_authentication.RejectionReason,
response: []const u8,
metric: ?connect_authentication.RejectionMetric,
