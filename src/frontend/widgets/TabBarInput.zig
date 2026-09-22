const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const Input = @This();

area: core.Rect,
tabs: ?*const data.TabsModel,
model: *const data.MultiplexerModel,
alignment: data.bar_values.Alignment = .right,
animation_frame: u8 = 0,
