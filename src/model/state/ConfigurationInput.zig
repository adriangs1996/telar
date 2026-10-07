const BarLayout = @import("../bars/BarLayout.zig");
const Config = @import("Config.zig");

generation: u64,
sidebar_visible: bool,
pane_gaps: bool,
bars: BarLayout = .{},
config: Config = .{},
/// Borrowed only for the synchronous transition; copied into the model.
window_title: []const u8 = "",
