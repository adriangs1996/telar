const Client = @import("../../Client.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const RectType = @import("telar-core").Rect;
const Context = @This();

client: *Client,
model: *MultiplexerModel,
area: RectType,
