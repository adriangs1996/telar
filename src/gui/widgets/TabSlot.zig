const core = @import("telar-core");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const TabSlot = @This();

id: core.TabId,
bounds: Rect,
immediate: bool = false,
