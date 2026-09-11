const ModelType = @import("../../model/Model.zig");
const ConfirmPaneAttachment = @import("ConfirmPaneAttachment.zig");
const types = @import("../../model/types.zig");
const std = @import("std");
const ConfirmPaneAttachmentHandler = @This();

model: *ModelType,

/// Validates the runtime confirmation before committing client attachment
/// state. Confirmations made stale by a tab change are harmless no-ops.
///
/// ```zig
/// const result = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmPaneAttachmentHandler, command: ConfirmPaneAttachment) !types.PaneAttachmentConfirmation {
    if (command.created or !std.meta.eql(command.requested, command.confirmed)) {
        return error.UnexpectedPane;
    }

    return handler.model.confirmPaneAttachment(command.confirmed);
}
