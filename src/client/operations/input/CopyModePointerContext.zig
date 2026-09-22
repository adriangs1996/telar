const data = @import("model");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const Context = @This();

client: *Client,
model: *data.MultiplexerModel,
area: core.Rect,
