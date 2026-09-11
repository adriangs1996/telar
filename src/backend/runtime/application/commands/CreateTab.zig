const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LaunchViewType = @import("telar-core").LaunchView;
const CreateTab = @This();

workspace: WorkspaceLocationType,
/// Borrowed only for the synchronous `execute` call.
label: []const u8,
size: TerminalSizeType,
/// Every slice in this view is borrowed only for `execute`.
launch: LaunchViewType,
