const connect_authentication = @import("connect_authentication.zig");
const ExpectedRejection = @This();

reason: connect_authentication.RejectionReason,
response: []const u8,
metric: ?connect_authentication.RejectionMetric,
