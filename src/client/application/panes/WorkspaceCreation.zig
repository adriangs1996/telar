const WorkspaceCreation = @This();
const source_namespace = @import("pane_open_delivery.zig");
const OpenedPane = @import("OpenedPane.zig");
requested_size: source_namespace.schema.TerminalSize,
opened: OpenedPane,
