const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const Effects = @This();

context: *anyopaque,
project_view: *const fn (*anyopaque, bool, u16) void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
offer_pane_geometry: *const fn (*anyopaque, *MultiplexerModel) anyerror!void,
