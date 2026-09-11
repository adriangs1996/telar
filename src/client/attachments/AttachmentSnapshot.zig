const types = @import("types.zig");
const Item = @import("Item.zig");
const Snapshot = @This();

items: [types.max_items]Item = undefined,
len: u8 = 0,
modal: ?types.Id = null,

pub fn slice(snapshot: *const Snapshot) []const Item {
    return snapshot.items[0..snapshot.len];
}
