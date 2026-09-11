const CreatePane = @This();
const source_namespace = @import("pane.zig");
request_id: source_namespace.RequestId,
location: source_namespace.TabLocation,
size: source_namespace.TerminalSize,
launch: source_namespace.Launch,
