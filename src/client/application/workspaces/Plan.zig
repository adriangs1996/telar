const PaneTargetType = @import("telar-core").PaneTarget;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const Plan = @This();

target: PaneTargetType,
fallback_workspace: ?WorkspaceIdType,
