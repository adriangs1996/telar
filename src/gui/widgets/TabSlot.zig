const core = @import("telar-core");
const Rect = @import("../render/Rect.zig");
const TabSlot = @This();

id: core.TabId,
bounds: Rect,
immediate: bool = false,
