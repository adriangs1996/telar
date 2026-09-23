const core = @import("telar-core");
const AttachmentStore = @import("AttachmentStore.zig");
const attachment_mod = @import("attachment_namespace.zig");
const std = @import("std");
const Consumers = @This();

pane_id: core.PaneId,
stores: []const *AttachmentStore,

/// Example: `const needed = consumers.wants(key, true);`.
pub fn wants(self: Consumers, key: core.ImageKey, shared: bool) bool {
    for (self.stores) |store| {
        const attachment = store.find(self.pane_id) orelse continue;
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
