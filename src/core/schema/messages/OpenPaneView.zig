const id = @import("../id.zig");
const types = @import("../types.zig");
const TerminalSize = @import("../TerminalSize.zig");
const LaunchView = @import("LaunchView.zig");

request_id: id.RequestId,
target: types.PaneTarget,
size: TerminalSize,
launch: ?LaunchView,
