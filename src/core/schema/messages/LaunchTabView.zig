const id = @import("../id.zig");
const TerminalSize = @import("../TerminalSize.zig");
const LaunchView = @import("LaunchView.zig");

request_id: id.RequestId,
workspace: id.WorkspaceId,
label: []const u8,
size: TerminalSize,
launch: LaunchView,
