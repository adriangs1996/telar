const id = @import("../id.zig");
/// Asks the runtime's engine for one shell command that fulfils `text` in
/// the context of `pane_id` (its cwd and visible screen).
const SuggestCommand = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
text: []const u8,
