const ConfigurationInput = @This();
const bars_module = @import("../bars/root.zig");
generation: u64,
sidebar_visible: bool,
pane_gaps: bool,
bars: bars_module.Layout = .{},
/// Borrowed only for the synchronous transition; copied into the model.
window_title: []const u8 = "",
