const data = @import("model");
const client = @import("telar-client");
const Resources = @import("Resources.zig");
const CellPresentation = @This();

projection: client.Projection,
resources: Resources,
model: *const data.MultiplexerModel,
force: bool,
