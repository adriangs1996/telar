const data = @import("model");
const core = @import("telar-core");
const model_data = @import("model");
const Plan = @This();

thumbnails: [data.attachment_types.max_items]PlanItem = undefined,
thumbnail_count: u8 = 0,
modal: ?PlanItem = null,

pub fn thumbnailSlice(self: *const Plan) []const PlanItem {
    return self.thumbnails[0..self.thumbnail_count];
}

const PlanItem = struct {
    id: model_data.AttachmentId,
    area: core.Rect,
};
