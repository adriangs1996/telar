const model_data = @import("model");
const Item = @import("Item.zig");
const Snapshot = @This();

items: [model_data.attachment_types.max_items]Item = undefined,
len: u8 = 0,
modal: ?model_data.AttachmentId = null,

pub fn slice(snapshot: *const Snapshot) []const Item {
    return snapshot.items[0..snapshot.len];
}
