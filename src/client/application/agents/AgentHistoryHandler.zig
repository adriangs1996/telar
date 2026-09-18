//! Disposable navigation and admission for bounded historical reading windows.
const core = @import("telar-core");
const Model = @import("../../model/Model.zig");
const Pane = @import("../../panes/Pane.zig");
const Window = @import("../../panes/AgentHistoryWindow.zig");
const Operation = @import("../../connection/AgentHistoryOperation.zig");
const Handler = @This();

model: *Model,

/// Input records only bounded intent; preparation and allocation occur later.
/// Example: `_ = handler.navigate(id, .older);`
pub fn navigate(handler: Handler, id: core.PaneId, direction: core.agent_history.Direction) bool {
    const pane = handler.findPane(id) orelse return false;
    if (pane.agent_history == null and direction == .newer) {
        return false;
    }
    if (pane.agent_history == null) {
        const live = pane.agent_thread orelse return false;
        if (!live.truncated) {
            const incomplete = for (live.items()) |item| {
                if (!item.fragment_end) {
                    break true;
                }
            } else false;
            if (!incomplete) {
                return false;
            }
        }
    }
    if (pane.agent_history) |window| {
        if (window.retained) {
            return false;
        }
        if (window.pending) |pending| {
            if (pending == direction) {
                return false;
            }
            pane.history_generation +%= 1;
            window.generation = pane.history_generation;
            window.pending = null;
        }
        if (direction == .older and !window.has(.older)) {
            return false;
        }
        window.scan_remaining = Window.max_scan_pages;
        if (direction != window.direction) {
            window.preserve_seam = false;
        }
    }
    pane.history_intent = direction;
    handler.invalidate(id);
    return true;
}

/// Continues a delivered page containing only already folded work, without input.
/// Example: `_ = handler.skipFolded(id);`
pub fn skipFolded(handler: Handler, id: core.PaneId) bool {
    const pane = handler.findPane(id) orelse return false;
    const window = pane.agent_history orelse return false;
    if (window.retained or window.failed or window.pending != null or pane.history_intent != null or !window.has(window.direction)) {
        return false;
    }

    window.preserve_seam = true;
    if (window.scan_remaining == 0) {
        return false;
    }

    window.scan_remaining -= 1;
    pane.history_intent = window.direction;
    handler.invalidate(id);
    return true;
}

/// Loads adjacent context without treating frame delivery as a new gesture.
/// Example: `handler.prefetch(id, .older);`
pub fn prefetch(handler: Handler, id: core.PaneId, direction: core.agent_history.Direction) void {
    const pane = handler.findPane(id) orelse return;
    const window = pane.agent_history orelse {
        _ = handler.navigate(id, direction);
        return;
    };
    if (window.retained or window.failed or window.pending != null or pane.history_intent != null or window.scan_remaining == 0 or !window.has(direction)) {
        return;
    }

    window.scan_remaining -= 1;
    window.preserve_seam = false;
    pane.history_intent = direction;
    handler.invalidate(id);
}

/// Restores omitted activity bytes through normal correlated history requests.
/// Example: `handler.revealWork(id, group_key);`
pub fn revealWork(handler: Handler, id: core.PaneId, key: u64) void {
    const pane = handler.findPane(id) orelse return;
    const window = pane.agent_history orelse return;
    if (window.retained) {
        return;
    }

    const direction = window.revealWork(key);
    if (direction == null and !window.preserve_seam) {
        return;
    }

    window.pending = null;
    window.preserve_seam = false;
    window.scan_remaining = Window.max_scan_pages;
    pane.history_generation +%= 1;
    window.generation = pane.history_generation;
    pane.history_intent = direction;
    handler.invalidate(id);
}

/// Freezes the seam and plans one page after input and presentation finish.
/// Example: `const query = try handler.begin(id) orelse return;`
pub fn begin(handler: Handler, id: core.PaneId) !?core.QueryAgentHistory {
    const pane = handler.findPane(id) orelse return null;
    const direction = pane.history_intent orelse return null;
    errdefer {
        pane.history_intent = null;
        handler.invalidate(id);
    }
    const window = (try handler.ensureWindow(pane)) orelse return null;
    pane.history_intent = null;
    if (window.retained) {
        return null;
    }
    if (!window.has(direction)) {
        if (direction == .newer and pane.followAgentThread()) {
            handler.invalidate(id);
        }
        return null;
    }
    pane.history_generation +%= 1;
    window.generation = pane.history_generation;
    window.pending = direction;
    window.direction = direction;
    window.failed = false;
    handler.invalidate(id);
    const cursor = window.cursor(direction);
    return .{ .request_id = @enumFromInt(0), .pane_id = id, .pane_generation = pane.pane_generation, .view_generation = window.generation, .direction = direction, .cursor = cursor, .anchor = if (cursor.len == 0 and direction == .older) window.anchor() else "", .anchor_turn = if (cursor.len == 0 and direction == .older) window.anchorTurn() else "" };
}

/// Owns selection bytes before presentation without starting provider work.
/// Pending pages become stale so a response cannot evict selected content.
/// Example: `if (try handler.freeze(id, attachment)) prepareSelection();`
pub fn freeze(handler: Handler, id: core.PaneId, attachment: u64) !bool {
    const pane = handler.findPane(id) orelse return false;
    if (pane.attachment_generation != attachment) {
        return false;
    }

    const created = pane.agent_history == null;
    const window = (try handler.ensureWindow(pane)) orelse return false;
    if (window.retained) {
        return true;
    }

    window.retained = true;
    window.selection_only = created;
    pane.history_generation +%= 1;
    window.generation = pane.history_generation;
    window.pending = null;
    pane.history_intent = null;
    handler.invalidate(id);
    return true;
}

/// Selection-only snapshots return to live output; existing history stays readable.
/// Example: `handler.unfreeze(id, attachment);`
pub fn unfreeze(handler: Handler, id: core.PaneId, attachment: u64) void {
    const pane = handler.findPane(id) orelse return;
    if (pane.attachment_generation != attachment) {
        return;
    }

    const window = pane.agent_history orelse return;
    if (!window.retained) {
        return;
    }

    if (window.selection_only) {
        pane.clearHistory();
    } else {
        window.retained = false;
        _ = pane.followAgentThread();
    }
    handler.invalidate(id);
}

/// Owns the validated page only after exact request and attachment admission.
/// Example: `_ = try handler.apply(operation, response);`
pub fn apply(handler: Handler, operation: Operation, response: core.AgentHistoryPageView) !bool {
    const pane = handler.resolve(operation) orelse return false;
    if (response.view_generation != operation.view_generation or response.snapshot.pane_id != pane.id or response.snapshot.pane_generation != pane.pane_generation) {
        return error.InvalidHistoryResponse;
    }
    const replacement = try pane.gpa.create(core.AgentHistoryPage);
    defer pane.gpa.destroy(replacement);
    try response.copyTo(replacement);
    const changed = pane.agent_history.?.apply(replacement);
    if (changed) {
        _ = pane.followAgentThread();
        handler.invalidate(pane.id);
    }
    return changed;
}

/// Failed requests stay readable and retry only after another navigation gesture.
/// Example: `_ = handler.failed(operation, message);`
pub fn failed(handler: Handler, operation: Operation, message: []const u8) bool {
    const pane = handler.resolve(operation) orelse return false;
    pane.agent_history.?.fail(message);
    handler.invalidate(pane.id);
    return true;
}

/// Retiring a stale response wakes only visible navigation waiting for its slot.
/// Example: `handler.retired();`
pub fn retired(handler: Handler) void {
    const tab = handler.model.activeTabModelConst() orelse return;
    for (tab.panes) |entry| {
        const value = entry orelse continue;
        if (value.history_intent != null) {
            handler.model.panes_revision +%= 1;
            return;
        }
    }
}

/// Commits delivered geometry without confusing it with a new scroll gesture.
/// Example: `handler.anchor(id, resolved_scroll);`
pub fn anchor(handler: Handler, id: core.PaneId, scroll: f64) void {
    const value = handler.findPane(id) orelse return;
    value.transcript_scroll = scroll;
    value.transcript_anchor_revision +%= 1;
    handler.invalidate(id);
}

/// Fresh scroll input renews prefetch and invalidates an opposing request.
/// Example: `handler.reverse(id, .newer);`
pub fn reverse(handler: Handler, id: core.PaneId, direction: core.agent_history.Direction) void {
    const value = handler.findPane(id) orelse return;
    const window = value.agent_history orelse return;
    if (window.retained) {
        return;
    }

    if (window.scan_remaining != Window.max_scan_pages) {
        window.scan_remaining = Window.max_scan_pages;
        handler.invalidate(id);
    }

    const pending = window.pending orelse return;
    if (pending == direction) {
        return;
    }
    value.history_generation +%= 1;
    window.generation = value.history_generation;
    window.pending = null;
    value.history_intent = null;
    window.direction = direction;
    window.preserve_seam = false;
    handler.invalidate(id);
}

fn invalidate(handler: Handler, id: core.PaneId) void {
    const tab = handler.model.activeTabModelConst() orelse return;
    if (tab.findConst(id) != null) {
        handler.model.panes_revision +%= 1;
    }
}

fn resolve(handler: Handler, operation: Operation) ?*Pane {
    const value = handler.findPane(operation.owner.pane_id) orelse return null;
    if (value.attachment_generation != operation.owner.attachment_generation or value.pane_generation != operation.owner.pane_generation) {
        return null;
    }
    const window = value.agent_history orelse return null;
    return if (window.generation == operation.view_generation and window.pending != null) value else null;
}

fn findPane(handler: Handler, id: core.PaneId) ?*Pane {
    const value = handler.model.workspace.findPane(id) orelse return null;
    return if (value.attached and value.kind == .agent) value else null;
}

fn ensureWindow(handler: Handler, pane: *Pane) !?*Window {
    if (pane.agent_history) |existing| {
        return existing;
    }
    const live = pane.agent_thread orelse return null;
    try handler.reserveWindow();
    const created = try pane.gpa.create(Window);
    pane.history_generation +%= 1;
    created.start(live, pane.history_generation);
    pane.agent_history = created;
    return created;
}

fn reserveWindow(handler: Handler) !void {
    var count: usize = 0;
    var inactive: ?*Pane = null;
    for (&handler.model.workspace.items, 0..) |*slot, index| {
        const tab = if (slot.*) |*value| value else continue;
        for (&tab.model.panes) |*entry| {
            const value = if (entry.*) |*present| present else continue;
            if (value.agent_history != null) {
                count += 1;
                if (index != handler.model.workspace.active_index and !value.agent_history.?.retained) {
                    inactive = value;
                }
            }
        }
    }
    if (count < 16) {
        return;
    }
    if (inactive) |value| {
        value.clearHistory();
        value.transcript_scroll = 0;
        return;
    }
    return error.AgentHistoryCapacity;
}
