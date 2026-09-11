const ViewType = @import("telar-client").LayoutView;
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const PaneProgressStateType = @import("telar-core").PaneProgressState;
const PaletteType = @import("../ui/Palette.zig");
const BorderInput = @This();

view: ViewType,
foreground_name: []const u8,
fullscreen_model: ?*const MultiplexerModel = null,
progress_state: PaneProgressStateType,
progress_percent: ?u8,
animation_frame: u8,
palette: *const PaletteType,
