//! Where a component list is on the Lua stack and where it will be shown.
const Surface = @import("component_values.zig").Surface;

index: c_int,
surface: Surface,
