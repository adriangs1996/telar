//! Frame-local geometry for a bounded conversation. Row identity never is position.
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const View = @import("ThreadItemView.zig");
const Flow = @This();

bounds: Rect,
thread: @import("telar-client").ThreadView,
rows: [4 * core.agent_thread.max_items]View = undefined,
len: usize = 0,
height: f32 = 0,
scroll_limit: u32 = 0,
resolved_scroll: u32 = 0,
reanchored: bool = false,

/// Measures retained items once, then moves the visible window from its end.
/// Example: `try flow.resolve(canvas);`
pub fn resolve(flow: *Flow, canvas: *Canvas) !void {
    const live = flow.thread.transcript orelse return;
    flow.len = 0;
    flow.reanchored = false;
    flow.height = canvas.chrome.px(12);
    const pages: [2]?*const core.AgentThreadSnapshot = if (flow.thread.history) |window| .{ &window.pages[0].snapshot, if (window.count == 2) &window.pages[1].snapshot else null } else .{ live, null };
    var items: [2 * core.agent_thread.max_items]View = undefined;
    var item_count: usize = 0;
    for (pages, 0..) |optional, page_index| {
        const snapshot = optional orelse continue;
        const order = @import("ThreadOrder.zig").resolve(snapshot.items());
        for (order.indices[0..order.len]) |index| {
            const item = &snapshot.items()[index];
            if (page_index == 0 and pages[1] != null and duplicate(snapshot, item, pages[1].?)) {
                continue;
            }
            const depth = parentDepth(snapshot, item);
            const indent = @min(canvas.chrome.px(@as(f32, @floatFromInt(depth)) * 22), flow.bounds.width * 0.22);
            var view: View = .{ .thread = flow.thread, .item = item, .bounds = .{ .x = flow.bounds.x + indent, .y = flow.height, .width = @max(1, flow.bounds.width - indent), .height = 0 }, .viewport = flow.bounds, .depth = depth };
            view.thread.transcript = snapshot;
            if (canvas.widgets) |state| {
                view.expanded = state.threadExpanded(view.control());
            }

            items[item_count] = view;
            item_count += 1;
        }
    }

    const conversation = @import("ThreadConversation.zig").resolve(items[0..item_count], canvas.widgets);
    flow.len = conversation.len;
    @memcpy(flow.rows[0..flow.len], conversation.rows[0..conversation.len]);
    for (flow.rows[0..flow.len], 0..) |*view, index| {
        view.bounds.y = flow.height;
        if (view.work_count != 0) {
            view.bounds.x = flow.bounds.x;
            view.bounds.width = flow.bounds.width;
        }
        view.bounds.height = if (view.work_count != 0) @import("ThreadWork.zig").measure(canvas) else if (message(view.item)) try (@import("ThreadMessage.zig"){ .view = view.* }).measure(canvas) else if (notice(view.item)) try noticeText(view.*).measure(canvas) + canvas.chrome.px(20) else try (@import("ThreadActivity.zig"){ .view = view.* }).measure(canvas);
        flow.height += view.bounds.height;
        if (canvas.widgets) |state| {
            if (view.work_count == 0) {
                const text = try state.threadText(canvas.atlas.allocator);
                text.maps.preparing().addRow(view.*, @intCast(index));
            }
        }
    }

    const maximum = @max(0, flow.height - flow.bounds.height);
    flow.scroll_limit = @intFromFloat(@min(@as(f64, @floatFromInt(@import("std").math.maxInt(u32))), @ceil(@as(f64, maximum) / canvas.chrome.px(24))));
    var scroll = @min(flow.thread.transcript_scroll, flow.scroll_limit);
    // Retire offsets left behind by shrinking or folded content on delivery.
    flow.reanchored = scroll != flow.thread.transcript_scroll;
    if (canvas.widgets) |state| {
        const registry = state.dispatcher.maps.presented();
        for (registry.targets[0..registry.len]) |target| {
            if (target.action != .transcript or target.action.transcript != flow.thread.pane_id or target.id.generation != flow.thread.attachment_generation) {
                continue;
            }
            const changed = target.thread_window_revision != flow.windowRevision() or target.thread_history_generation != flow.thread.history_generation or target.bounds.width != flow.bounds.width or target.bounds.height != flow.bounds.height;
            if ((flow.thread.history != null or flow.thread.transcript_scroll > 0) and (changed or target.thread_reanchor and target.thread_anchor_revision == flow.thread.transcript_anchor_revision and target.thread_resolved_scroll != target.thread_scroll_value)) {
                const newer = if (flow.thread.history) |window| window.direction == .newer else false;
                const key = if (newer) target.thread_last_key else target.thread_first_key;
                const offset = if (newer) target.thread_last_offset else target.thread_first_offset;
                const baseline = if (target.thread_anchor_revision != flow.thread.transcript_anchor_revision) target.thread_resolved_scroll else target.thread_scroll_value;
                const movement = @as(f32, @floatFromInt(@as(i64, flow.thread.transcript_scroll) - baseline)) * canvas.chrome.px(24);
                for (flow.rows[0..flow.len]) |view| {
                    if (itemKey(view) == key and key != 0) {
                        const desired = @round((maximum - view.bounds.y + offset + movement) / canvas.chrome.px(24));
                        scroll = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(flow.scroll_limit)), desired)));
                        flow.reanchored = true;
                        break;
                    }
                }
            }
            break;
        }
        for (flow.rows[0..flow.len]) |view| {
            scroll = state.thread_anchor.resolve(.{ .control = view.control(), .baseline = flow.thread.transcript_scroll, .offset = view.bounds.y, .maximum = maximum, .step = canvas.chrome.px(24), .limit = flow.scroll_limit }) orelse continue;
            flow.reanchored = false;
            break;
        }
    }
    flow.resolved_scroll = scroll;

    const first = @max(0, maximum - @as(f32, @floatFromInt(scroll)) * canvas.chrome.px(24));
    for (flow.rows[0..flow.len]) |*view| {
        view.bounds.y += flow.bounds.y - first;
    }
}

/// Captures bounded row anchors in the same registry as the delivered viewport.
/// Example: `const target = flow.navigation(target);`
pub fn navigation(flow: *const Flow, original: @import("interaction/Target.zig")) @import("interaction/Target.zig") {
    var target = original;
    target.thread_window_revision = flow.windowRevision();
    target.thread_history_generation = flow.thread.history_generation;
    target.thread_scroll_value = flow.thread.transcript_scroll;
    target.thread_anchor_revision = flow.thread.transcript_anchor_revision;
    target.thread_resolved_scroll = flow.resolved_scroll;
    target.thread_reanchor = flow.reanchored;
    target.thread_skip_folded = flow.skipFolded();
    var visible_header = false;
    for (flow.rows[0..flow.len]) |view| {
        if (view.bounds.y + view.bounds.height <= flow.bounds.y or view.bounds.y >= flow.bounds.y + flow.bounds.height) {
            continue;
        }
        if (target.thread_first_key == 0 or (!visible_header and view.bounds.y >= flow.bounds.y)) {
            target.thread_first_key = itemKey(view);
            target.thread_first_offset = view.bounds.y - flow.bounds.y;
            visible_header = view.bounds.y >= flow.bounds.y;
        }
        target.thread_last_key = itemKey(view);
        target.thread_last_offset = view.bounds.y - flow.bounds.y;
    }
    return target;
}

fn skipFolded(flow: *const Flow) bool {
    const window = flow.thread.history orelse return false;
    if (window.retained or window.failed or window.pending != null) {
        return false;
    }

    const older = window.direction == .older;
    if ((older and flow.resolved_scroll < flow.scroll_limit) or (!older and flow.resolved_scroll != 0)) {
        return false;
    }

    if (window.count == 1) {
        if (flow.height >= flow.bounds.height) {
            return false;
        }

        for (flow.rows[0..flow.len]) |row| {
            if (row.work_count != 0 and !row.expanded) {
                return true;
            }
        }

        return false;
    }

    const scanned = &window.pages[if (older) @as(usize, 0) else 1].snapshot;
    const retained = &window.pages[if (older) @as(usize, 1) else 0].snapshot;
    if (scanned.item_count == 0 or retained.item_count == 0) {
        return false;
    }

    const Conversation = @import("ThreadConversation.zig");
    const seam = &retained.items()[if (older) @as(usize, 0) else retained.item_count - 1];
    var shared: View = .{ .thread = flow.thread, .item = seam, .bounds = flow.bounds, .viewport = flow.bounds };
    shared.thread.transcript = retained;
    const key = Conversation.workKey(shared) orelse return false;
    for (scanned.items()) |*item| {
        var view: View = .{ .thread = flow.thread, .item = item, .bounds = flow.bounds, .viewport = flow.bounds };
        view.thread.transcript = scanned;
        if (Conversation.workKey(view) != key) {
            return false;
        }
    }

    for (flow.rows[0..flow.len]) |row| {
        if (row.work_count != 0 and row.work_key == key) {
            return !row.expanded;
        }
    }

    return false;
}

fn windowRevision(flow: *const Flow) u64 {
    return if (flow.thread.history) |window| window.revision else if (flow.thread.transcript) |snapshot| snapshot.revision else 0;
}

fn itemKey(view: View) u64 {
    if (view.work_count != 0) {
        return view.work_key;
    }

    return @import("telar-client").AgentHistoryWindow.itemKey(view.thread.transcript.?, view.item);
}

fn duplicate(snapshot: *const core.AgentThreadSnapshot, item: *const core.AgentThreadItem, newer: *const core.AgentThreadSnapshot) bool {
    for (newer.items()) |*candidate| {
        if (@import("telar-client").AgentHistoryWindow.sameFragment(.{ .snapshot = snapshot, .item = item }, .{ .snapshot = newer, .item = candidate })) {
            return true;
        }
    }
    return false;
}

/// Only visible rows paint or request the next animation frame.
/// Example: `try flow.draw(canvas);`
pub fn draw(flow: *const Flow, canvas: *Canvas) !void {
    for (flow.rows[0..flow.len]) |view| {
        if (view.bounds.y + view.bounds.height <= flow.bounds.y or view.bounds.y >= flow.bounds.y + flow.bounds.height) {
            continue;
        }

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
