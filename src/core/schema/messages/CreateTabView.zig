const id = @import("../id.zig");
const types = @import("../types.zig");
const TerminalSize = @import("../TerminalSize.zig");
const LaunchView = @import("LaunchView.zig");
const CreateTabView = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
label: []const u8,
size: TerminalSize,
launch: LaunchView,
