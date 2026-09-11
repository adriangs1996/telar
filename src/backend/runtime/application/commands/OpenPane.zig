const OpenPane = @This();
const source_namespace = @import("open_pane.zig");
target: source_namespace.schema.PaneTarget,
size: source_namespace.schema.TerminalSize,
launch: ?source_namespace.schema.LaunchView,
