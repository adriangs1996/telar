const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const PaneDescriptorType = @import("../PaneDescriptor.zig");
const TabSnapshot = @This();

request_id: id.RequestId,
location: TabLocationType,
panes: []const PaneDescriptorType,
