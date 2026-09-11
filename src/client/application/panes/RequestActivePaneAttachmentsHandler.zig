const ModelType = @import("../../model/Model.zig");
const PaneAttachmentRequestsEffects = @import("PaneAttachmentRequestsEffects.zig");
const RectType = @import("telar-core").Rect;
const RequestPaneAttachmentsHandler = @import("RequestPaneAttachmentsHandler.zig");
const RequestActivePaneAttachmentsHandler = @This();

model: *ModelType,
effects: PaneAttachmentRequestsEffects,

/// Selects the active tab once its canonical snapshot has loaded and
/// requests the attachments its detached visible panes are missing. Used
/// after a geometry change, so a pane skipped by a crowded layout attaches
/// as soon as it fits.
///
/// ```zig
/// const count = try handler.execute(area);
/// ```
pub fn execute(handler: *RequestActivePaneAttachmentsHandler, area: RectType) !usize {
    const active = handler.model.workspace.active() orelse return 0;
    if (!active.snapshot_loaded) {
        return 0;
    }

    var request: RequestPaneAttachmentsHandler = .{ .effects = handler.effects };
    return request.execute(active, area);
}
