const CreateTab = @This();
const source_namespace = @import("create_tab.zig");
workspace: source_namespace.schema.WorkspaceLocation,
/// Borrowed only for the synchronous `execute` call.
label: []const u8,
size: source_namespace.schema.TerminalSize,
/// Every slice in this view is borrowed only for `execute`.
launch: source_namespace.schema.LaunchView,
