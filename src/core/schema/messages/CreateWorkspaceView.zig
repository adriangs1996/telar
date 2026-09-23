const id = @import("../id.zig");
const TerminalSize = @import("../TerminalSize.zig");
const LaunchView = @import("LaunchView.zig");
const CreateWorkspaceView = @This();

request_id: id.RequestId,
size: TerminalSize,
name: []const u8,
launch: LaunchView,
create_cwd: bool = false,
