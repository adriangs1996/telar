const core = @import("telar-core");
/// What a registration asks the table to hold. Text is validated on the wire
/// and again here, so a restored record cannot smuggle a longer value in.
const WorktreeRegistration = @This();

id: ?core.WorktreeId = null,
source: core.WorkspaceId,
created_by: ?core.PaneId = null,
coordinator: ?core.CoordinatorReference = null,
origin: core.WorktreeOrigin = .telar,
path: []const u8,
branch: []const u8,
base: []const u8 = "",
title: []const u8 = "",
brief: []const u8 = "",
dispatched_from: []const u8 = "",
