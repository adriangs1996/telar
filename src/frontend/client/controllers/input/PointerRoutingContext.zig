const Context = @This();
const Client = @import("../../Client.zig");
const source_namespace = @import("pointer_routing.zig");
client: *Client,
model: ?*source_namespace.multiplexer.Model = null,
