const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const TerminalSize = @import("../TerminalSize.zig");
const Launch = @import("../Launch.zig");
const CreatePane = @This();

request_id: id.RequestId,
location: TabLocation,
size: TerminalSize,
launch: Launch,
