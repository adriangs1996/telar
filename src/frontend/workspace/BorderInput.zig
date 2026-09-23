const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const BorderInput = @This();

view: data.LayoutView,
foreground_name: []const u8,
/// The client model when the pane is fullscreen, with its tab's slot.
fullscreen_model: ?*const data.Model = null,
tab: usize = 0,
progress_state: core.PaneProgressState,
progress_percent: ?u8,
animation_frame: u8,
palette: *const data.Palette,
