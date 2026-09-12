const Client = @import("../../AttachedClient.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const Context = @This();

client: *Client,
model: ?*MultiplexerModel = null,
