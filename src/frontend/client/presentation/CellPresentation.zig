const Projection = @import("telar-client").Projection;
const Resources = @import("Resources.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const CellPresentation = @This();

projection: Projection,
resources: Resources,
model: *const MultiplexerModel,
force: bool,
