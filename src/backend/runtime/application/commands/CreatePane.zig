const CreatePane = @This();
const source_namespace = @import("create_pane.zig");
location: source_namespace.schema.TabLocation,
size: source_namespace.schema.TerminalSize,
/// Every slice in this view is borrowed only for `execute`.
launch: source_namespace.schema.LaunchView,
