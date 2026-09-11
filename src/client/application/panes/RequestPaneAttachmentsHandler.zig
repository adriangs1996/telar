const PaneAttachmentRequestsEffects = @import("PaneAttachmentRequestsEffects.zig");
const TabType = @import("../../workspace/Tab.zig");
const RectType = @import("telar-core").Rect;
const RequestPaneAttachmentsHandler = @This();

effects: PaneAttachmentRequestsEffects,

/// Requests an attachment for each detached pane of `tab` that has visible
/// content in `area`, and returns how many it requested. A pane with a
/// request already pending is left alone. A pane without content cannot
/// carry a terminal size, so it stays detached until the geometry changes
/// and a later offer finds room for it. The runtime owns membership, so an
/// unattachable pane is a degraded view, never a failure.
///
/// ```zig
/// const count = try handler.execute(tab, area);
/// ```
pub fn execute(handler: *RequestPaneAttachmentsHandler, tab: *TabType, area: RectType) !usize {
    var count: usize = 0;
    var panes = tab.model.paneIterator();
    while (panes.next()) |pane| {
        if (pane.attached or handler.effects.attachment_pending(handler.effects.context, pane.id)) {
            continue;
        }

        const size = tab.model.contentSize(pane.id, area) orelse continue;
        try handler.effects.request_attachment(handler.effects.context, .{
            .pane_id = pane.id,
            .location = tab.location,
            .size = size,
        });
        count += 1;
    }

    return count;
}
