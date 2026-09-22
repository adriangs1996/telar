const core = @import("telar-core");
const data = @import("model");
const client = @import("telar-client");
const Preparation = @This();

area: core.Rect,
center: *const data.Center,
palette: *const client.Palette,
icon_theme: client.Theme = .unicode,
