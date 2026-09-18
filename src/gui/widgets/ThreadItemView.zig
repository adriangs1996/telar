//! A synchronous item borrow. Interaction targets copy only its stable identity.
const core = @import("telar-core");
const View = @This();

thread: @import("telar-client").ThreadView,
item: *const core.AgentThreadItem,
bounds: @import("../render/Rect.zig"),
viewport: @import("../render/Rect.zig"),
expanded: bool = false,
depth: u8 = 0,
work_count: u16 = 0,
work_key: u64 = 0,
work_active: bool = false,

/// Resolves the delivered item without carrying a snapshot pointer into input.
/// Example: `const action = view.control();`
pub fn control(view: View) @import("interaction/ThreadItemControl.zig") {
    if (view.work_count != 0) {
        return .{ .pane_id = view.thread.pane_id, .attachment_generation = view.thread.attachment_generation, .identity = view.item.identity, .source_key = view.work_key, .operation = .toggle_work };
    }

    return .{ .pane_id = view.thread.pane_id, .attachment_generation = view.thread.attachment_generation, .identity = view.item.identity, .source_key = if (view.item.sourceId(view.thread.transcript.?).len > 0) @import("telar-client").AgentHistoryWindow.itemKey(view.thread.transcript.?, view.item) else 0 };
}

/// Example: `if (view.active()) drawLiveStatus();`
pub fn active(view: View) bool {
    return view.thread.history == null and (view.item.status == .pending or view.item.status == .running);
}

/// Example: `try draw(view.text());`
pub fn text(view: View) []const u8 {
    return view.item.text(view.thread.transcript.?);
}

/// Identifies immutable source bytes without retaining the snapshot borrow.
/// Example: `const owner = view.source(.body);`
pub fn source(view: View, section: @FieldType(@import("MessageLayoutOwner.zig"), "section")) @import("MessageLayoutOwner.zig") {
    const snapshot = view.thread.transcript.?;
    return .{ .pane_id = view.thread.pane_id, .attachment_generation = view.thread.attachment_generation, .pane_generation = snapshot.pane_generation, .snapshot_revision = snapshot.revision, .item_identity = view.item.identity, .section = section, .source_offset = if (section == .body) view.item.text_offset else view.item.detail_offset };
}
