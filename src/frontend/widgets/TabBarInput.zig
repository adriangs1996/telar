const RectType = @import("telar-core").Rect;
const TabsModel = @import("telar-client").TabsModel;
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const AlignmentType = @import("telar-client").Alignment;
const Input = @This();

area: RectType,
tabs: ?*const TabsModel,
model: *const MultiplexerModel,
alignment: AlignmentType = .right,
animation_frame: u8 = 0,
