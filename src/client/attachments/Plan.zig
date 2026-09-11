const Plan = @This();
const source_namespace = @import("types.zig");
const PlanItem = @import("PlanItem.zig");
thumbnails: [source_namespace.max_items]PlanItem = undefined,
thumbnail_count: u8 = 0,
modal: ?PlanItem = null,

pub fn thumbnailSlice(plan: *const Plan) []const PlanItem {
    return plan.thumbnails[0..plan.thumbnail_count];
}
