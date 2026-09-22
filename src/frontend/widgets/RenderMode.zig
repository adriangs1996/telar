const core = @import("telar-core");
const data = @import("model");
const RenderMode = @This();

area: core.Rect,
center: *const data.Center,
paint: bool,
