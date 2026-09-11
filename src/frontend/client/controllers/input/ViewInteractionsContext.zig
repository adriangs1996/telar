const Context = @This();
const Client = @import("../../Client.zig");
const source_namespace = @import("view_interactions.zig");
client: *Client,
model: *source_namespace.multiplexer.Model,
