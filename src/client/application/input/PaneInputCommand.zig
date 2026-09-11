const types = @import("../../model/types.zig");
const pane_input = @import("pane_input.zig");
const Command = @This();

target: types.PaneInputTarget,
source: pane_input.Source,
payload: pane_input.Payload,
