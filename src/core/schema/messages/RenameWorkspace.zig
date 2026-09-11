const id = @import("../id.zig");
const types = @import("../types.zig");
const RenameWorkspace = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
name: []const u8,
