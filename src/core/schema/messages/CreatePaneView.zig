const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const LaunchViewType = @import("LaunchView.zig");
const CreatePaneView = @This();

request_id: id.RequestId,
location: TabLocationType,
size: TerminalSizeType,
launch: LaunchViewType,
