//! Bounded presentation rows. Work is folded without changing the transcript.
const std = @import("std");
const View = @import("ThreadItemView.zig");
const State = @import("interaction/State.zig");
const Conversation = @This();

rows: []View,
len: usize = 0,
group: ?usize = null,

/// Appends ordered items directly to the frame's rows, keeping folded groups compact.
/// Example: `conversation.push(view, state);`
pub fn push(conversation: *Conversation, view: View, state: ?*const State) void {
    if (!work(view)) {
        conversation.group = null;
        conversation.append(view);
        return;
    }

    if (conversation.group) |index| {
        if (!sameTurn(conversation.rows[index], view)) {
            conversation.group = null;
        }
    }
    if (conversation.group == null) {
        var header = view;
        const snapshot = view.thread.transcript.?;
        header.depth = 0;
        header.work_count = 0;
        header.work_key = turnKey(header);
        header.work_active = view.thread.history == null and snapshot.status == .working and snapshot.currentTurnId().len > 0 and std.mem.eql(u8, snapshot.currentTurnId(), view.item.sourceTurn(snapshot));
        // The control uses the disclosure key when work_count is nonzero.
        header.work_count = 1;
        header.expanded = if (state) |value| value.threadExpanded(header.control()) else false;
        header.work_count = 0;
        conversation.group = conversation.len;
        conversation.append(header);
    }

    const header = &conversation.rows[conversation.group.?];
    header.work_count += 1;
    header.work_active = header.work_active or view.active();
    if (header.expanded) {
        conversation.append(view);
    }
}

fn append(conversation: *Conversation, view: View) void {
    conversation.rows[conversation.len] = view;
    conversation.len += 1;
}

/// Identifies work that contributes only a shared disclosure while folded.
/// Example: `const key = ThreadConversation.workKey(view) orelse return false;`
pub fn workKey(view: View) ?u64 {
    return if (work(view)) turnKey(view) else null;
}

fn work(view: View) bool {
    const item = view.item;
    if (item.parent_identity != 0) {
        return true;
    }

    if (item.kind == .system or item.role == .system or item.role == .user) {
        return false;
    }

    // An absent phase is not evidence that a public response is commentary.
    return item.kind != .message or item.role != .assistant or item.phase == .commentary;
}

fn sameTurn(first: View, next: View) bool {
    if (next.item.parent_identity != 0) {
        return true;
    }

    const first_turn = first.item.sourceTurn(first.thread.transcript.?);
    const next_turn = next.item.sourceTurn(next.thread.transcript.?);
    if (first_turn.len > 0 and next_turn.len > 0) {
        return std.mem.eql(u8, first_turn, next_turn);
    }

    return first.item.turn_identity == next.item.turn_identity;
}

fn turnKey(view: View) u64 {
    return @import("telar-client").AgentHistoryWindow.groupKey(view.thread.transcript.?, view.item);
}
