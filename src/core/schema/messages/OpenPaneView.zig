const id = @import("../id.zig");
const types = @import("../types.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const LaunchViewType = @import("LaunchView.zig");
const OpenPaneView = @This();

request_id: id.RequestId,
target: types.PaneTarget,
size: TerminalSizeType,
launch: ?LaunchViewType,
