const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const TerminalSize = @import("../TerminalSize.zig");
const LaunchView = @import("LaunchView.zig");
const CreatePaneView = @This();

request_id: id.RequestId,
location: TabLocation,
size: TerminalSize,
launch: LaunchView,
