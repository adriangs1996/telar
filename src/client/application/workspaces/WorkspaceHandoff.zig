const PaneTargetType = @import("telar-core").PaneTarget;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const TerminalSizeType = @import("telar-core").TerminalSize;
const WorkspaceHandoff = @This();

target: PaneTargetType,
fallback_workspace: ?WorkspaceIdType,
size: TerminalSizeType,
