const PaneIdType = @import("telar-core").PaneId;
const AttachmentStoreType = @import("../../../attachment/AttachmentStore.zig");
const ImageKeyType = @import("telar-core").ImageKey;
const attachment_mod = @import("../../../attachment/attachment_namespace.zig");
const std = @import("std");
const Consumers = @This();

pane_id: PaneIdType,
stores: []const *AttachmentStoreType,

/// Example: `const needed = consumers.wants(key, true);`.
pub fn wants(consumers: Consumers, key: ImageKeyType, shared: bool) bool {
    for (consumers.stores) |store| {
        const attachment = store.find(consumers.pane_id) orelse continue;
        if (attachment.graphics.shared_transport != shared or attachment_mod.knowsImage(attachment, key)) {
            continue;
        }
        if (attachment.graphics.transfer) |transfer| {
            if (std.meta.eql(transfer.metadata.key, key)) {
                continue;
            }
        }

        return true;
    }

    return false;
}
