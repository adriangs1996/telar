const model_data = @import("model");
const pane_input = @import("pane_input.zig");
const Command = @This();

target: model_data.PaneInputTarget,
source: pane_input.Source,
payload: pane_input.Payload,
