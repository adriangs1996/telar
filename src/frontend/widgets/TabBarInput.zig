const core = @import("telar-core");
const client = @import("telar-client");
const Input = @This();

area: core.Rect,
tabs: ?*const client.TabsModel,
model: *const client.MultiplexerModel,
alignment: client.Alignment = .right,
animation_frame: u8 = 0,
