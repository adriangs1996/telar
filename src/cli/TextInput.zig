const core = @import("telar-core");

mode: core.PaneTextMode,
text: []const u8,
/// The pane this process runs in, named on the prompt the runtime delivers.
sender: ?u64 = null,
