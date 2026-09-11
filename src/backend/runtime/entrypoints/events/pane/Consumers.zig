const Consumers = @This();
const core = @import("telar-core");
const source_namespace = @import("media_projection.zig");
const attachment_mod = @import("../../../attachment/root.zig");
const std = @import("std");
pane_id: core.schema.PaneId,
stores: []const *source_namespace.AttachmentStore,

/// Example: `const needed = consumers.wants(key, true);`.
pub fn wants(consumers: Consumers, key: core.graphics.ImageKey, shared: bool) bool {
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
