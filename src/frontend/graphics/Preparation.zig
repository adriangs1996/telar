const core = @import("telar-core");
const data = @import("model");
const client = @import("telar-client");
const Preparation = @This();

area: core.Rect,
center: *const data.Center,
palette: *const data.Palette,
icon_theme: data.icons.Theme = .unicode,
