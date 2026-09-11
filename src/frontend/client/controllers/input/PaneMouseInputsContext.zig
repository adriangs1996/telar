const Context = @This();
const Client = @import("../../Client.zig");
const source_namespace = @import("pane_mouse_inputs.zig");
client: *Client,
model: *source_namespace.multiplexer.Model,
area: source_namespace.ui.Rect,
