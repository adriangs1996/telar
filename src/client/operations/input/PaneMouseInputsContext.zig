const Client = @import("../../AttachedClient.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const RectType = @import("telar-core").Rect;
const Context = @This();

client: *Client,
model: *MultiplexerModel,
area: RectType,
