const Client = @import("../../Client.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const Context = @This();

client: *Client,
model: ?*MultiplexerModel = null,
