const data = @import("model");
const Client = @import("../../AttachedClient.zig");
const Context = @This();

client: *Client,
model: ?*data.MultiplexerModel = null,
