const ProxyStatusDelivery = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
deliver: *const fn (*anyopaque, client_model.ProxyStatusCommit) anyerror!void,
