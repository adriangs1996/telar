const id = @import("../id.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const LaunchType = @import("../Launch.zig");
/// Forces a named workspace identity at `launch.cwd`. Unlike `open_pane`, this
/// never attaches to an existing workspace with the same path. The name is
/// explicit and remains independent from pane cwd changes.
const CreateWorkspace = @This();

request_id: id.RequestId,
size: TerminalSizeType,
name: []const u8,
launch: LaunchType,
