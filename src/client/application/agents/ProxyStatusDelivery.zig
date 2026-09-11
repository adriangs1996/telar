const ProxyStatusCommitType = @import("../../model/ProxyStatusCommit.zig");
const ProxyStatusDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, ProxyStatusCommitType) anyerror!void,
