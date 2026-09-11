const CreatedTabType = @import("../workspace/CreatedTab.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const NewTab = @This();

created: CreatedTabType,
size: TerminalSizeType,
