const data = @import("model");
const client = @import("telar-client");
const ThreadSurfaceInput = @This();

view: client.ThreadView,
palette: *const data.Palette,
