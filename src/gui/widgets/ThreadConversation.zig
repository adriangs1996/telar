//! Bounded presentation rows. Work is folded without changing the transcript.
const std = @import("std");
const core = @import("telar-core");
const View = @import("ThreadItemView.zig");
const State = @import("interaction/State.zig");
const Conversation = @This();

rows: [4 * core.agent_thread.max_items]View = undefined,
len: usize = 0,

/// Groups consecutive work across page seams, preserving public messages and notices.
/// Example: `const conversation = ThreadConversation.resolve(items, state);`
pub fn resolve(items: []const View, state: ?*const State) Conversation {
    std.debug.assert(items.len <= 2 * core.agent_thread.max_items);
    var conversation: Conversation = .{};
    var index: usize = 0;
    while (index < items.len) {
        if (!work(items[index])) {
            conversation.append(items[index]);
            index += 1;
            continue;
        }

        const first = index;
        const snapshot = items[first].thread.transcript.?;
        var active = items[first].thread.history == null and snapshot.status == .working and snapshot.currentTurnId().len > 0 and std.mem.eql(u8, snapshot.currentTurnId(), items[first].item.sourceTurn(snapshot));
        while (index < items.len and work(items[index]) and sameTurn(items[first], items[index])) : (index += 1) {
            active = active or items[index].active();
        }

        var header = items[first];
        header.depth = 0;
        header.work_count = @intCast(index - first);
        header.work_key = turnKey(header);
        header.work_active = active;
        header.expanded = if (state) |value| value.threadExpanded(header.control()) else false;
        conversation.append(header);
        if (header.expanded) {
            for (items[first..index]) |view| {
                conversation.append(view);
            }
        }
    }

    return conversation;
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
    const turn = view.item.sourceTurn(view.thread.transcript.?);
    if (turn.len == 0) {
        return if (view.item.turn_identity != 0) view.item.turn_identity else view.item.identity;
    }

    var hash = std.hash.Wyhash.init(0x776f726b7475726e);
    hash.update(view.thread.transcript.?.threadId());
    hash.update(&.{0});
    hash.update(turn);
    return hash.final() | 1;
}
