const WorkspaceIdType = @import("telar-core").WorkspaceId;
const FailureCodeType = @import("telar-core").FailureCode;
const WorkspaceHandoffFailure = @This();

fallback_workspace: ?WorkspaceIdType,
code: FailureCodeType,
