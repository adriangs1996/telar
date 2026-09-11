const TerminalSizeType = @import("telar-core").TerminalSize;
const LaunchViewType = @import("telar-core").LaunchView;
const CreateWorkspace = @This();

/// Borrowed only for the synchronous `execute` call.
name: []const u8,
size: TerminalSizeType,
/// Every slice in this view is borrowed only for `execute`.
launch: LaunchViewType,
