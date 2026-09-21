const Client = @import("../../AttachedClient.zig");
const std = @import("std");
const ConfirmPaneAttachment = @import("../../application/panes/ConfirmPaneAttachment.zig");
const PaneAttachment = @import("../../model/PaneAttachment.zig");
const types = @import("../../model/types.zig");
const tab_snapshots = @import("../tabs/tab_snapshots.zig");

/// Validates correlation before committing attachment; late confirmations may be stale. Example: `_ = try confirm(client, command);`
pub fn confirm(client: *Client, command: ConfirmPaneAttachment) !types.PaneAttachmentConfirmation {
    if (command.created or !std.meta.eql(command.requested, command.confirmed)) {
        return error.UnexpectedPane;
    }

    return client.model.confirmPaneAttachment(command.confirmed);
}

/// Repairs failed membership only while the attachment remains active and detached. Example: `_ = try recover(client, attachment);`
pub fn recover(client: *Client, attachment: PaneAttachment) !bool {
    if (!client.model.needsPaneAttachment(attachment)) {
        return false;
    }

    _ = try tab_snapshots.recover(client, attachment.location);
    return true;
}
