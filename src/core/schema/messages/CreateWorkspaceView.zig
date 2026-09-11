const CreateWorkspaceView = @This();
const source_namespace = @import("workspace.zig");
request_id: source_namespace.RequestId,
size: source_namespace.TerminalSize,
name: []const u8,
launch: source_namespace.LaunchView,
