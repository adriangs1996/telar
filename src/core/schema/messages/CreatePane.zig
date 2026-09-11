const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const TerminalSizeType = @import("../TerminalSize.zig");
const LaunchType = @import("../Launch.zig");
const CreatePane = @This();

request_id: id.RequestId,
location: TabLocationType,
size: TerminalSizeType,
launch: LaunchType,
