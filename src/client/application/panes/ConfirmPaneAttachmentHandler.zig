const ConfirmPaneAttachmentHandler = @This();
const client_model = @import("../../root.zig").model;
const ConfirmPaneAttachment = @import("ConfirmPaneAttachment.zig");
const std = @import("std");
model: *client_model.Model,

/// Validates the runtime confirmation before committing client attachment
/// state. Confirmations made stale by a tab change are harmless no-ops.
///
/// ```zig
/// const result = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmPaneAttachmentHandler, command: ConfirmPaneAttachment) !client_model.PaneAttachmentConfirmation {
    if (command.created or !std.meta.eql(command.requested, command.confirmed)) {
        return error.UnexpectedPane;
    }

    return handler.model.confirmPaneAttachment(command.confirmed);
}
