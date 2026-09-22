const core = @import("telar-core");
const CreateTab = @This();

workspace: core.WorkspaceLocation,
/// Borrowed only for the synchronous `execute` call.
label: []const u8,
size: core.TerminalSize,
/// Every slice in this view is borrowed only for `execute`.
launch: core.LaunchView,

kind: core.PaneKind = .terminal,
