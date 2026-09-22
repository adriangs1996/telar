const core = @import("telar-core");
const ReviewService = @import("../change_review/Service.zig");
const std = @import("std");
const ServiceType = @import("../history/Service.zig");
const GraphicsBudgetType = @import("../media/GraphicsBudget.zig");
const CreationResources = @This();

io: std.Io,
gpa: std.mem.Allocator,
history_service: *ServiceType,
review_service: ?*ReviewService = null,
graphics_budget: *GraphicsBudgetType,
/// Runtime-owned, immutable after startup; shared with observation
/// workers.
manifests: *const core.Table = &core.builtin_table,

environment: std.process.Environ = .empty,
