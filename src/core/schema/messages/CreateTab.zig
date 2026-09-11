const id = @import("../id.zig");
const types = @import("../types.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const LaunchType = @import("../Launch.zig");
const CreateTab = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
label: []const u8 = "",
size: TerminalSizeType,
launch: LaunchType,
