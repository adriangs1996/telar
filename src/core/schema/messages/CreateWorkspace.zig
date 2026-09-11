/// Forces a named workspace identity at `launch.cwd`. Unlike `open_pane`, this
/// never attaches to an existing workspace with the same path. The name is
/// explicit and remains independent from pane cwd changes.
const CreateWorkspace = @This();
const source_namespace = @import("workspace.zig");
request_id: source_namespace.RequestId,
size: source_namespace.TerminalSize,
name: []const u8,
launch: source_namespace.Launch,
