const Context = @This();
const Client = @import("../../Client.zig");
const source_namespace = @import("copy_mode_pointer.zig");
client: *Client,
model: *source_namespace.multiplexer.Model,
area: source_namespace.ui.Rect,
