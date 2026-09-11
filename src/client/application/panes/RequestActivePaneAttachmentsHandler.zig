const RequestActivePaneAttachmentsHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PaneAttachmentRequestsEffects.zig");
const source_namespace = @import("pane_attachment_requests.zig");
const RequestPaneAttachmentsHandler = @import("RequestPaneAttachmentsHandler.zig");
model: *client_model.Model,
effects: Effects,

/// Selects the active tab once its canonical snapshot has loaded and
/// requests the attachments its detached visible panes are missing. Used
/// after a geometry change, so a pane skipped by a crowded layout attaches
/// as soon as it fits.
///
/// ```zig
/// const count = try handler.execute(area);
/// ```
pub fn execute(handler: *RequestActivePaneAttachmentsHandler, area: source_namespace.ui.Rect) !usize {
    const active = handler.model.workspace.active() orelse return 0;
    if (!active.snapshot_loaded) {
        return 0;
    }

    var request: RequestPaneAttachmentsHandler = .{ .effects = handler.effects };
    return request.execute(active, area);
}
