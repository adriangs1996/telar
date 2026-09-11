const RequestIdType = @import("telar-core").RequestId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PendingWorkspaceSnapshot = @This();

request_id: RequestIdType,
workspace: WorkspaceLocationType,
