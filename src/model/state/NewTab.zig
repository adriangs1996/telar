const core = @import("telar-core");
const CreatedTab = @import("../workspace/CreatedTab.zig");
const NewTab = @This();

created: CreatedTab,
size: core.TerminalSize,
