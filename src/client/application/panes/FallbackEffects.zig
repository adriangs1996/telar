const PaneIdType = @import("telar-core").PaneId;
const FallbackEffects = @This();

context: *anyopaque,
has_graphics: *const fn (*anyopaque, PaneIdType) bool,
