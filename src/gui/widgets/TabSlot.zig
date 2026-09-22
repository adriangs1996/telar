const core = @import("telar-core");
const TabSlot = @This();

id: core.TabId,
bounds: @import("../render/Rect.zig"),
immediate: bool = false,
