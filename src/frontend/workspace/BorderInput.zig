const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const BorderInput = @This();

view: data.LayoutView,
foreground_name: []const u8,
fullscreen_model: ?*const data.MultiplexerModel = null,
progress_state: core.PaneProgressState,
progress_percent: ?u8,
animation_frame: u8,
palette: *const data.Palette,
