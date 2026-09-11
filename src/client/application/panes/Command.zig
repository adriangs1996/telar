const Command = @This();
const source_namespace = @import("pane_open_delivery.zig");
const OpenedPane = @import("OpenedPane.zig");
continuation: source_namespace.Continuation,
opened: OpenedPane,
