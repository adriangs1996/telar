const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const Input = @This();

area: core.Rect,
names: []const []const u8,
focused: usize,
palette: *const data.Palette,
