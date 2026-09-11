const Snapshot = @This();
const source_namespace = @import("types.zig");
const Item = @import("Item.zig");
items: [source_namespace.max_items]Item = undefined,
len: u8 = 0,
modal: ?source_namespace.Id = null,

pub fn slice(snapshot: *const Snapshot) []const Item {
    return snapshot.items[0..snapshot.len];
}
