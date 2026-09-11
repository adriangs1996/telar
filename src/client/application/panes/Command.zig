const pane_open_delivery = @import("pane_open_delivery.zig");
const OpenedPane = @import("OpenedPane.zig");
const Command = @This();

continuation: pane_open_delivery.Continuation,
opened: OpenedPane,
