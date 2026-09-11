const SetPaneViewportHandler = @This();
const source_namespace = @import("pane_viewport.zig");
const SetPaneViewport = @import("SetPaneViewport.zig");
attachments: *source_namespace.AttachmentStore,

/// Changes only the requesting client's scrollback pin. Requests that
/// resolve to the current offset are idempotent and do not schedule a new
/// snapshot.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id, .offset = 0 });
/// ```
pub fn execute(handler: *SetPaneViewportHandler, command: SetPaneViewport) !source_namespace.SetPaneViewportResult {
    const update = try handler.attachments.setPaneViewport(.{
        .pane_id = command.pane_id,
        .offset = command.offset,
    }) orelse return .pane_not_attached;

    return switch (update) {
        .changed => .changed,
        .unchanged => .unchanged,
    };
}
