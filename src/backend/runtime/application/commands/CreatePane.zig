const TabLocationType = @import("telar-core").TabLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LaunchViewType = @import("telar-core").LaunchView;
const CreatePane = @This();

location: TabLocationType,
size: TerminalSizeType,
/// Every slice in this view is borrowed only for `execute`.
launch: LaunchViewType,
