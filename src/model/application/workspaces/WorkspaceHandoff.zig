const core = @import("telar-core");
const WorkspaceHandoff = @This();

target: core.PaneTarget,
fallback_workspace: ?core.WorkspaceId,
size: core.TerminalSize,
