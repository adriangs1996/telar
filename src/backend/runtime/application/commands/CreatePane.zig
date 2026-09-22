const core = @import("telar-core");
const CreatePane = @This();

location: core.TabLocation,
size: core.TerminalSize,
/// Every slice in this view is borrowed only for `execute`.
launch: core.LaunchView,
