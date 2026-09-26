//! Where a component list is on the Lua stack and where it will be shown.
const Surface = @import("component_values.zig").Surface;
const ComponentSource = @This();

index: c_int,
surface: Surface,
