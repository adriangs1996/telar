const id = @import("../id.zig");
const TerminalSize = @import("../TerminalSize.zig");
const LaunchView = @import("LaunchView.zig");
const LaunchTabView = @This();

request_id: id.RequestId,
workspace: id.WorkspaceId,
label: []const u8,
size: TerminalSize,
launch: LaunchView,
