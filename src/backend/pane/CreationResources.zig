const core = @import("telar-core");
const std = @import("std");
const Service = @import("../history/Service.zig");
const GraphicsBudget = @import("../media/GraphicsBudget.zig");
const CreationResources = @This();

io: std.Io,
gpa: std.mem.Allocator,
history_service: *Service,
graphics_budget: *GraphicsBudget,
/// Runtime-owned, immutable after startup; shared with observation
/// workers.
manifests: *const core.Table = &core.builtin_table,
