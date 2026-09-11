const id = @import("../id.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const LaunchViewType = @import("LaunchView.zig");
const CreateWorkspaceView = @This();

request_id: id.RequestId,
size: TerminalSizeType,
name: []const u8,
launch: LaunchViewType,
