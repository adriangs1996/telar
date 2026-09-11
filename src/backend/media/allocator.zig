//! Bounded media allocations and runtime-wide budget accounting.

const std = @import("std");
const core = @import("telar-core");

pub const GraphicsLimits = @import("GraphicsLimits.zig");

pub const ParkingMutex = @import("ParkingMutex.zig");

pub const GraphicsBudget = @import("GraphicsBudget.zig");

pub const PaneMediaAllocator = @import("PaneMediaAllocator.zig");
