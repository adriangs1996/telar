const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const Context = @This();

client: *Client,
model: *MultiplexerModel,
area: core.Rect,
