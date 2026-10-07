const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const PaneDescriptor = @import("../PaneDescriptor.zig");

request_id: id.RequestId,
location: TabLocation,
panes: []const PaneDescriptor,
