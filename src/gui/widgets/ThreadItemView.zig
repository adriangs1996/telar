//! A synchronous item borrow. Interaction targets copy only its stable identity.
const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const Rect = @import("../render/Rect.zig");
const ThreadItemControl = @import("interaction/ThreadItemControl.zig");
const MessageLayoutOwner = @import("MessageLayoutOwner.zig");
const View = @This();

thread: client.ThreadView,
item: *const core.AgentThreadItem,
bounds: Rect,
viewport: Rect,
expanded: bool = false,
depth: u8 = 0,
work_count: u16 = 0,
work_key: u64 = 0,
work_active: bool = false,

/// Resolves the delivered item without carrying a snapshot pointer into input.
/// Example: `const action = view.control();`
pub fn control(self: View) ThreadItemControl {
    if (self.work_count != 0) {
        return .{ .pane_id = self.thread.pane_id, .attachment_generation = self.thread.attachment_generation, .identity = self.item.identity, .source_key = self.work_key, .operation = .toggle_work };
    }

    return .{ .pane_id = self.thread.pane_id, .attachment_generation = self.thread.attachment_generation, .identity = self.item.identity, .source_key = if (self.item.sourceId(self.thread.transcript.?).len > 0) data.AgentHistoryWindow.itemKey(self.thread.transcript.?, self.item) else 0 };
}

/// Example: `if (view.active()) drawLiveStatus();`
pub fn active(self: View) bool {
    return self.thread.history == null and (self.item.status == .pending or self.item.status == .running);
}

/// Example: `try draw(view.text());`
pub fn text(self: View) []const u8 {
    return self.item.text(self.thread.transcript.?);
}

/// Identifies immutable source bytes without retaining the snapshot borrow.
/// Example: `const owner = view.source(.body);`
pub fn source(self: View, section: @FieldType(MessageLayoutOwner, "section")) MessageLayoutOwner {
    const snapshot = self.thread.transcript.?;
    return .{ .pane_id = self.thread.pane_id, .attachment_generation = self.thread.attachment_generation, .pane_generation = snapshot.pane_generation, .snapshot_revision = snapshot.revision, .item_identity = self.item.identity, .section = section, .source_offset = if (section == .body) self.item.text_offset else self.item.detail_offset };
}
