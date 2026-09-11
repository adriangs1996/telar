const types = @import("../../model/types.zig");
const HistoryPaste = @This();

target: types.PaneInputTarget,
text: []const u8,
run: bool,
