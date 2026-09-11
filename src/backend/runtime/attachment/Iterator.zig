const AttachmentStoreType = @import("AttachmentStore.zig");
const Attachment = @import("Attachment.zig");
const Iterator = @This();

store: *const AttachmentStoreType,
position: usize = 0,

pub fn next(self: *Iterator) ?*const Attachment {
    while (self.position < self.store.items.len) {
        defer self.position += 1;
        if (self.store.items[self.position]) |*value| {
            return value;
        }
    }
    return null;
}
