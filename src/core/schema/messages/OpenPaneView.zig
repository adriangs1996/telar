const OpenPaneView = @This();
const source_namespace = @import("pane.zig");
request_id: source_namespace.RequestId,
target: source_namespace.PaneTarget,
size: source_namespace.TerminalSize,
launch: ?source_namespace.LaunchView,
