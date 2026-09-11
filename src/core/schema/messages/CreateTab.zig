const CreateTab = @This();
const source_namespace = @import("tab.zig");
request_id: source_namespace.RequestId,
workspace: source_namespace.WorkspaceLocation,
label: []const u8 = "",
size: source_namespace.TerminalSize,
launch: source_namespace.Launch,
