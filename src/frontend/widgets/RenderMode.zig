const RectType = @import("telar-core").Rect;
const CenterType = @import("telar-client").Center;
const RenderMode = @This();

area: RectType,
center: *const CenterType,
paint: bool,
