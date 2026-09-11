const id = @import("../id.zig");
const types = @import("../types.zig");
const RequestWorkspaceSnapshot = @This();

request_id: id.RequestId,
workspace: types.WorkspaceLocation,
