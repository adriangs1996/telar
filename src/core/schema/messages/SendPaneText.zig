const id = @import("../id.zig");
const types = @import("../types.zig");
/// Text delivered to one exact pane generation without a client attachment.
const SendPaneText = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
mode: types.PaneTextMode,
text: []const u8,
/// The pane whose process sent the text, when it runs inside telar. The
/// runtime names it on the receiving prompt and budgets prompts per sender.
sender: ?id.PaneId = null,
