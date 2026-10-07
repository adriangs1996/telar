const id = @import("../id.zig");
const types = @import("../types.zig");

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
name: []const u8,
