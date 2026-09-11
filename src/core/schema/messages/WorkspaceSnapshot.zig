const id = @import("../id.zig");
const types = @import("../types.zig");
const TabDescriptorType = @import("../TabDescriptor.zig");
const WorkspaceSnapshot = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
name: []const u8,
tabs: []const TabDescriptorType,
