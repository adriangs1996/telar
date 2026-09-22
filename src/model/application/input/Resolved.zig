const PaneMousePlanType = @import("../../workspace/PaneMousePlan.zig");
const PointerCommand = @import("PointerCommand.zig");
const Resolved = @This();

plan: PaneMousePlanType,
pointer: PointerCommand,
