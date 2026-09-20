const ReviewService = @import("../change_review/Service.zig");
const std = @import("std");
const ServiceType = @import("../history/Service.zig");
const GraphicsBudgetType = @import("../media/GraphicsBudget.zig");
const TableType = @import("telar-core").Table;
const builtin_table_module = @import("telar-core").builtin_table;
const CreationResources = @This();

io: std.Io,
gpa: std.mem.Allocator,
history_service: *ServiceType,
review_service: ?*ReviewService = null,
graphics_budget: *GraphicsBudgetType,
/// Runtime-owned, immutable after startup; shared with observation
/// workers.
manifests: *const TableType = &builtin_table_module,

environment: @import("std").process.Environ = .empty,
