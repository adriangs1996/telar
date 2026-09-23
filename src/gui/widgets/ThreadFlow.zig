//! Frame-local geometry for a bounded conversation. Row identity never is position.
const data = @import("model");
const ThreadOrder = @import("ThreadOrder.zig");
const ThreadWork = @import("ThreadWork.zig");
const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const View = @import("ThreadItemView.zig");
const Flow = @This();

bounds: Rect,
thread: client.ThreadView,
rows: [2 * data.AgentHistoryWindow.capacity * core.agent_thread.max_items]View = undefined,
len: usize = 0,
height: f32 = 0,
scroll_limit: f64 = 0,
resolved_scroll: f64 = 0,
destination_scroll: f64 = 0,
scroll_step: f32 = 24,
reanchored: bool = false,

/// Measures retained items once, then moves the visible window from its end.
/// Example: `try flow.resolve(canvas);`
pub fn resolve(self: *Flow, canvas: *Canvas) !void {
    core.profiling.add(.agent_resolve, 1);
    var profile_items: u64 = 0;
    defer core.profiling.add(.agent_items, profile_items);
    const live = self.thread.transcript orelse return;
    self.len = 0;
    self.reanchored = false;
    self.height = canvas.chrome.px(12);
    self.scroll_step = canvas.chrome.px(24);
    var conversation: @import("ThreadConversation.zig") = .{ .rows = &self.rows };
    const page_count: usize = if (self.thread.history) |window| window.count else 1;
    const unique = if (self.thread.history) |window| uniqueItems(window) else null;

    for (0..page_count) |page_index| {
        const snapshot = if (self.thread.history) |window| &window.pages[page_index].snapshot else live;
        const order = ThreadOrder.resolve(snapshot.items());

        for (order.indices[0..order.len]) |index| {
            profile_items += 1;
            const item = &snapshot.items()[index];
            if (unique) |masks| {
                if (masks[page_index] & (@as(u64, 1) << @intCast(index)) == 0) {
                    continue;
                }
            }
            const depth = parentDepth(snapshot, item);
            const indent = @min(canvas.chrome.px(@as(f32, @floatFromInt(depth)) * 22), self.bounds.width * 0.22);
            var view: View = .{ .thread = self.thread, .item = item, .bounds = .{ .x = self.bounds.x + indent, .y = self.height, .width = @max(1, self.bounds.width - indent), .height = 0 }, .viewport = self.bounds, .depth = depth };
            view.thread.transcript = snapshot;
            if (canvas.widgets) |state| {
                view.expanded = state.threadExpanded(view.control());
            }

            conversation.push(view, canvas.widgets);
        }
    }

    self.len = conversation.len;
    for (self.rows[0..self.len], 0..) |*view, index| {
        view.bounds.y = self.height;
        if (view.work_count != 0) {
            view.bounds.x = self.bounds.x;
            view.bounds.width = self.bounds.width;
        }
        view.bounds.height = if (view.work_count != 0) ThreadWork.measure(canvas) else if (message(view.item)) try (@import("ThreadMessage.zig"){ .view = view.* }).measure(canvas) else if (notice(view.item)) try noticeText(view.*).measure(canvas) + canvas.chrome.px(20) else try (@import("ThreadActivity.zig"){ .view = view.* }).measure(canvas);
        self.height += view.bounds.height;
        if (canvas.widgets) |state| {
            if (view.work_count == 0) {
                const text = try state.threadText(canvas.atlas.allocator);
                text.maps.preparing().addRow(view.*, @intCast(index));
            }
        }
    }

    const maximum = @max(0, self.height - self.bounds.height);
    self.scroll_limit = @as(f64, maximum) / canvas.chrome.px(24);
    var scroll = @min(self.thread.transcript_scroll, self.scroll_limit);
    // Retire offsets left behind by shrinking or folded content on delivery.
    self.reanchored = scroll != self.thread.transcript_scroll;
    if (canvas.widgets) |state| {
        const registry = state.dispatcher.maps.presented();
        for (registry.targets[0..registry.len]) |target| {
            if (target.action != .transcript or target.action.transcript != self.thread.pane_id or target.id.generation != self.thread.attachment_generation) {
                continue;
            }
            const changed = target.thread_window_revision != self.windowRevision() or target.thread_history_generation != self.thread.history_generation or target.bounds.width != self.bounds.width or target.bounds.height != self.bounds.height;
            const following_live = self.thread.transcript_scroll == 0 and target.thread_live_revision != self.liveRevision();
            if (!following_live and (self.thread.history != null or self.thread.transcript_scroll > 0) and (changed or target.thread_reanchor and target.thread_anchor_revision == self.thread.transcript_anchor_revision and target.thread_resolved_scroll != target.thread_scroll_value)) {
                const newer = if (self.thread.history) |window| window.direction == .newer else false;
                const key = if (newer) target.thread_last_key else target.thread_first_key;
                const offset = if (newer) target.thread_last_offset else target.thread_first_offset;
                const baseline = if (target.thread_anchor_revision != self.thread.transcript_anchor_revision) target.thread_resolved_scroll else target.thread_scroll_value;
                const movement = (self.thread.transcript_scroll - baseline) * canvas.chrome.px(24);
                for (self.rows[0..self.len]) |view| {
                    if (itemKey(view) == key and key != 0) {
                        const desired = (@as(f64, maximum) - view.bounds.y + offset + movement) / canvas.chrome.px(24);
                        scroll = @max(0, @min(self.scroll_limit, desired));
                        self.reanchored = true;
                        break;
                    }
                }
            }
            break;
        }
        for (self.rows[0..self.len]) |view| {
            scroll = state.thread_anchor.resolve(.{ .control = view.control(), .baseline = self.thread.transcript_scroll, .offset = view.bounds.y, .maximum = maximum, .step = canvas.chrome.px(24), .limit = self.scroll_limit }) orelse continue;
            self.reanchored = false;
            break;
        }
    }
    self.resolved_scroll = scroll;
    self.destination_scroll = scroll;
    if (canvas.widgets) |state| {
        if (state.thread_scroll.find(.{ .pane_id = self.thread.pane_id, .pane_generation = self.thread.attachment_generation })) |entry| {
            self.destination_scroll += (entry.motion.spring.target - entry.motion.spring.position) / self.scroll_step;
        }
    }

    const first = @max(0, maximum - @as(f32, @floatCast(scroll)) * canvas.chrome.px(24));
    for (self.rows[0..self.len]) |*view| {
        view.bounds.y += self.bounds.y - first;
    }
}

/// Captures bounded row anchors in the same registry as the delivered viewport.
/// Example: `const target = flow.navigation(target);`
pub fn navigation(self: *const Flow, original: @import("interaction/Target.zig")) @import("interaction/Target.zig") {
    var target = original;
    target.thread_window_revision = self.windowRevision();
    target.thread_live_revision = self.liveRevision();
    target.thread_history_generation = self.thread.history_generation;
    target.thread_scroll_value = self.thread.transcript_scroll;
    target.thread_anchor_revision = self.thread.transcript_anchor_revision;
    target.thread_resolved_scroll = self.resolved_scroll;
    target.thread_reanchor = self.reanchored;
    target.thread_skip_folded = self.skipFolded();
    target.thread_prefetch = self.prefetch();
    target.thread_has_older = if (self.thread.history) |window| window.has(.older) else if (self.thread.transcript) |live| live.truncated else false;
    target.thread_has_newer = if (self.thread.history) |window| window.has(.newer) else false;
    var visible_header = false;
    for (self.rows[0..self.len]) |view| {
        if (view.bounds.y + view.bounds.height <= self.bounds.y or view.bounds.y >= self.bounds.y + self.bounds.height) {
            continue;
        }
        if (target.thread_first_key == 0 or (!visible_header and view.bounds.y >= self.bounds.y)) {
            target.thread_first_key = itemKey(view);
            target.thread_first_offset = view.bounds.y - self.bounds.y;
            visible_header = view.bounds.y >= self.bounds.y;
        }
        target.thread_last_key = itemKey(view);
        target.thread_last_offset = view.bounds.y - self.bounds.y;
    }
    return target;
}

fn skipFolded(self: *const Flow) bool {
    const window = self.thread.history orelse return false;
    if (window.retained or window.failed or window.pending != null) {
        return false;
    }

    const older = window.direction == .older;
    const distance = (if (older) self.scroll_limit - @max(self.resolved_scroll, self.destination_scroll) else @min(self.resolved_scroll, self.destination_scroll)) * self.scroll_step;
    if (distance > self.bounds.height * 0.75) {
        return false;
    }

    if (window.count == 1) {
        if (self.height >= self.bounds.height) {
            return false;
        }

        for (self.rows[0..self.len]) |row| {
            if (row.work_count != 0 and !row.expanded) {
                return true;
            }
        }

        return false;
    }

    const scanned = &window.pages[if (older) @as(usize, 0) else window.count - 1].snapshot;
    const retained = &window.pages[if (older) @as(usize, 1) else window.count - 2].snapshot;
    if (scanned.item_count == 0 or retained.item_count == 0) {
        return false;
    }

    const Conversation = @import("ThreadConversation.zig");
    const seam = &retained.items()[if (older) @as(usize, 0) else retained.item_count - 1];
    var shared: View = .{ .thread = self.thread, .item = seam, .bounds = self.bounds, .viewport = self.bounds };
    shared.thread.transcript = retained;
    const key = Conversation.workKey(shared) orelse return false;
    for (scanned.items()) |*item| {
        var view: View = .{ .thread = self.thread, .item = item, .bounds = self.bounds, .viewport = self.bounds };
        view.thread.transcript = scanned;
        if (Conversation.workKey(view) != key) {
            return false;
        }
    }

    for (self.rows[0..self.len]) |row| {
        if (row.work_count != 0 and row.work_key == key) {
            return !row.expanded;
        }
    }

    return false;
}

fn prefetch(self: *const Flow) ?core.agent_history.Direction {
    const margin = self.bounds.height * 0.75;
    const top = (self.scroll_limit - @max(self.resolved_scroll, self.destination_scroll)) * self.scroll_step;
    const bottom = @min(self.resolved_scroll, self.destination_scroll) * self.scroll_step;
    const window = self.thread.history orelse {
        const live = self.thread.transcript orelse return null;
        if (top <= margin and live.truncated and (live.status == .ready or self.resolved_scroll > 0)) {
            return .older;
        }
        return null;
    };
    if (window.retained or window.failed or window.pending != null or window.scan_remaining == 0) {
        return null;
    }

    const direction: core.agent_history.Direction = if (top <= margin and window.has(.older)) .older else if (bottom <= margin and window.has(.newer)) .newer else return null;
    if (window.count == window.pages.len) {
        const evicted = &window.pages[if (direction == .older) window.count - 1 else @as(usize, 0)].snapshot;
        for (self.rows[0..self.len]) |row| {
            if (row.thread.transcript == evicted and row.bounds.y < self.bounds.y + self.bounds.height and row.bounds.y + row.bounds.height > self.bounds.y) {
                return null;
            }
        }
    }
    return direction;
}

fn windowRevision(self: *const Flow) u64 {
    return if (self.thread.history) |window| window.revision else if (self.thread.transcript) |snapshot| snapshot.revision else 0;
}

fn liveRevision(self: *const Flow) u64 {
    return if (self.thread.history) |window| window.live_revision else if (self.thread.transcript) |snapshot| snapshot.revision else 0;
}

fn itemKey(view: View) u64 {
    if (view.work_count != 0) {
        return view.work_key;
    }

    return data.AgentHistoryWindow.itemKey(view.thread.transcript.?, view.item);
}

fn uniqueItems(window: *const data.AgentHistoryWindow) [data.AgentHistoryWindow.capacity]u64 {
    const page_size = core.agent_thread.max_items;
    var masks: [data.AgentHistoryWindow.capacity]u64 = @splat(0);
    var slots: [2 * data.AgentHistoryWindow.capacity * page_size]u16 = @splat(0);
    var page_index: usize = window.count;
    while (page_index > 0) {
        page_index -= 1;
        const snapshot = &window.pages[page_index].snapshot;
        for (snapshot.items(), 0..) |*item, index| {
            if (item.source_len != 0) {
                var slot: usize = @intCast(data.AgentHistoryWindow.itemKey(snapshot, item) % slots.len);
                const repeated = while (slots[slot] != 0) : (slot = (slot + 1) % slots.len) {
                    const previous = slots[slot] - 1;
                    const newer = &window.pages[previous / page_size].snapshot;
                    if (data.AgentHistoryWindow.sameFragment(.{ .snapshot = snapshot, .item = item }, .{ .snapshot = newer, .item = &newer.items()[previous % page_size] })) {
                        break true;
                    }
                } else false;
                if (repeated) {
                    continue;
                }

                slots[slot] = @intCast(page_index * page_size + index + 1);
            }
            masks[page_index] |= @as(u64, 1) << @intCast(index);
        }
    }
    return masks;
}

/// Only visible rows paint or request the next animation frame.
/// Example: `try flow.draw(canvas);`
pub fn draw(self: *const Flow, canvas: *Canvas) !void {
    var considered: u64 = 0;
    var visible: u64 = 0;
    defer {
        core.profiling.add(.agent_draw_rows, considered);
        core.profiling.add(.agent_visible_rows, visible);
    }
    for (self.rows[0..self.len]) |view| {
        considered += 1;
        if (view.bounds.y + view.bounds.height <= self.bounds.y or view.bounds.y >= self.bounds.y + self.bounds.height) {
            continue;
        }

        visible += 1;
        if (view.work_count != 0) {
            try (@import("ThreadWork.zig"){ .view = view }).draw(canvas);
            continue;
        }

        if (view.depth > 0) {
            const rail_x = view.bounds.x - canvas.chrome.px(12);
            try canvas.fillAt(.{ .x = rail_x, .y = view.bounds.y, .width = 1, .height = canvas.chrome.px(17) }, canvas.theme.palette.overlay0);
            try canvas.fillAt(.{ .x = rail_x, .y = view.bounds.y + canvas.chrome.px(17), .width = canvas.chrome.px(9), .height = 1 }, canvas.theme.palette.overlay0);
        }

        if (message(view.item)) {
            try (@import("ThreadMessage.zig"){ .view = view }).draw(canvas);
        } else if (notice(view.item)) {
            try noticeText(view).draw(canvas);
        } else {
            try (@import("ThreadActivity.zig"){ .view = view }).draw(canvas);
        }
    }
}

fn message(item: *const core.AgentThreadItem) bool {
    return item.kind == .message and (item.role == .user or item.role == .assistant);
}

fn notice(item: *const core.AgentThreadItem) bool {
    return item.kind == .system or (item.kind == .message and item.role == .system);
}

fn noticeText(view: View) @import("MessageText.zig") {
    return .{ .bounds = view.bounds, .viewport = view.viewport, .text = view.text(), .markdown = false, .muted = true, .owner = view.source(.body) };
}

fn parentDepth(snapshot: *const core.AgentThreadSnapshot, item: *const core.AgentThreadItem) u8 {
    var parent = item.parent_identity;
    var depth: u8 = 0;
    while (parent != 0 and depth < 3) {
        var found = false;
        for (snapshot.items()) |candidate| {
            if (candidate.identity == parent and candidate.identity != item.identity) {
                depth += 1;
                parent = candidate.parent_identity;
                found = true;
                break;
            }
        }

        if (!found) {
            break;
        }
    }

    return depth;
}

test "dispatch topology uses stable parents and bounds malformed cycles" {
    const std = @import("std");
    const snapshot = try std.testing.allocator.create(core.AgentThreadSnapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 };
    snapshot.item_storage[0] = .{ .role = .tool, .kind = .dispatch, .identity = 10 };
    snapshot.item_storage[1] = .{ .role = .tool, .kind = .subagent, .identity = 12, .parent_identity = 10 };
    snapshot.item_storage[2] = .{ .role = .tool, .kind = .dispatch, .identity = 14, .parent_identity = 12 };
    snapshot.item_storage[3] = .{ .role = .tool, .kind = .subagent, .identity = 16, .parent_identity = 999 };
    snapshot.item_count = 4;
    try std.testing.expectEqual(@as(u8, 1), parentDepth(snapshot, &snapshot.item_storage[1]));
    try std.testing.expectEqual(@as(u8, 2), parentDepth(snapshot, &snapshot.item_storage[2]));
    try std.testing.expectEqual(@as(u8, 0), parentDepth(snapshot, &snapshot.item_storage[3]));
    snapshot.item_storage[0].parent_identity = 14;
    try std.testing.expect(parentDepth(snapshot, &snapshot.item_storage[1]) <= 3);
}
