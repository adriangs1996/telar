const CreateWorkspace = @This();
const source_namespace = @import("create_workspace.zig");
/// Borrowed only for the synchronous `execute` call.
name: []const u8,
size: source_namespace.schema.TerminalSize,
/// Every slice in this view is borrowed only for `execute`.
launch: source_namespace.schema.LaunchView,
