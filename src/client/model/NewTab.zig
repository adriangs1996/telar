const core = @import("telar-core");
const CreatedTabType = @import("../workspace/CreatedTab.zig");
const NewTab = @This();

created: CreatedTabType,
size: core.TerminalSize,
