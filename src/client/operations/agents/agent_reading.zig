//! Disposable navigation and admission for bounded historical reading windows.
const data = @import("model");
const core = @import("telar-core");

/// Input records only bounded intent; preparation and allocation occur later.
/// Example: `_ = navigate(model, id, .older);`
pub fn navigate(model: *data.Model, id: core.PaneId, direction: core.agent_history.Direction) bool {
    const pane = findPane(model, id) orelse return false;
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
        window.scan_remaining = data.AgentHistoryWindow.max_scan_pages;
        if (direction != window.direction) {
            window.preserve_seam = false;
        }
    }
    pane.history_intent = direction;
    invalidate(model, id);
    return true;
}

/// Continues a delivered page containing only already folded work, without input.
/// Example: `_ = skipFolded(model, id);`
pub fn skipFolded(model: *data.Model, id: core.PaneId) bool {
    const pane = findPane(model, id) orelse return false;
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
    invalidate(model, id);
    return true;
}

/// Loads adjacent context without treating frame delivery as a new gesture.
/// Example: `prefetch(model, id, .older);`
pub fn prefetch(model: *data.Model, id: core.PaneId, direction: core.agent_history.Direction) void {
    const pane = findPane(model, id) orelse return;
    const window = pane.agent_history orelse {
        _ = navigate(model, id, direction);
        return;
    };
    if (window.retained or window.failed or window.pending != null or pane.history_intent != null or window.scan_remaining == 0 or !window.has(direction)) {
        return;
    }

    window.scan_remaining -= 1;
    window.preserve_seam = false;
    pane.history_intent = direction;
    invalidate(model, id);
}

/// Restores omitted activity bytes through normal correlated history requests.
/// Example: `revealWork(model, id, group_key);`
pub fn revealWork(model: *data.Model, id: core.PaneId, key: u64) void {
    const pane = findPane(model, id) orelse return;
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
    window.scan_remaining = data.AgentHistoryWindow.max_scan_pages;
    pane.history_generation +%= 1;
    window.generation = pane.history_generation;
    pane.history_intent = direction;
    invalidate(model, id);
}

/// Freezes the seam and plans one page after input and presentation finish.
/// Example: `const query = try begin(model, id) orelse return;`
pub fn begin(model: *data.Model, id: core.PaneId) !?core.QueryAgentHistory {
    const pane = findPane(model, id) orelse return null;
    const direction = pane.history_intent orelse return null;
    errdefer {
        pane.history_intent = null;
        invalidate(model, id);
    }
    const window = (try ensureWindow(model, pane)) orelse return null;
    pane.history_intent = null;
    if (window.retained) {
        return null;
    }
    if (!window.has(direction)) {
        if (direction == .newer and pane.followAgentThread()) {
            invalidate(model, id);
        }
        return null;
    }
    pane.history_generation +%= 1;
    window.generation = pane.history_generation;
    window.pending = direction;
    window.direction = direction;
    window.failed = false;
    invalidate(model, id);
    const cursor = window.cursor(direction);
    return .{ .request_id = @enumFromInt(0), .pane_id = id, .pane_generation = pane.pane_generation, .view_generation = window.generation, .direction = direction, .cursor = cursor, .anchor = if (cursor.len == 0 and direction == .older) window.anchor() else "", .anchor_turn = if (cursor.len == 0 and direction == .older) window.anchorTurn() else "" };
}

/// Owns selection bytes before presentation without starting provider work.
/// Pending pages become stale so a response cannot evict selected content.
/// Example: `if (try freeze(model, id, attachment)) prepareSelection();`
pub fn freeze(model: *data.Model, id: core.PaneId, attachment: u64) !bool {
    const pane = findPane(model, id) orelse return false;
    if (pane.attachment_generation != attachment) {
        return false;
    }

    const created = pane.agent_history == null;
    const window = (try ensureWindow(model, pane)) orelse return false;
    if (window.retained) {
        return true;
    }

    window.retained = true;
    window.selection_only = created;
    pane.history_generation +%= 1;
    window.generation = pane.history_generation;
    window.pending = null;
    pane.history_intent = null;
    invalidate(model, id);
    return true;
}

/// Selection-only snapshots return to live output; existing history stays readable.
/// Example: `unfreeze(model, id, attachment);`
pub fn unfreeze(model: *data.Model, id: core.PaneId, attachment: u64) void {
    const pane = findPane(model, id) orelse return;
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
    invalidate(model, id);
}

/// Owns the validated page only after exact request and attachment admission.
/// Example: `_ = try apply(model, operation, response);`
pub fn apply(model: *data.Model, operation: data.AgentHistoryOperation, response: core.AgentHistoryPageView) !bool {
    const pane = resolve(model, operation) orelse return false;
    if (response.view_generation != operation.view_generation or response.snapshot.pane_id != pane.id or response.snapshot.pane_generation != pane.pane_generation) {
        return error.InvalidHistoryResponse;
    }
    const replacement = try pane.gpa.create(core.AgentHistoryPage);
    defer pane.gpa.destroy(replacement);
    try response.copyTo(replacement);
    const changed = pane.agent_history.?.apply(replacement);
    if (changed) {
        _ = pane.followAgentThread();
        invalidate(model, pane.id);
    }
    return changed;
}

/// Failed requests stay readable and retry only after another navigation gesture.
/// Example: `_ = failed(model, operation, message);`
pub fn failed(model: *data.Model, operation: data.AgentHistoryOperation, message: []const u8) bool {
    const pane = resolve(model, operation) orelse return false;
    pane.agent_history.?.fail(message);
    invalidate(model, pane.id);
    return true;
}

/// Retiring a stale response wakes only visible navigation waiting for its slot.
/// Example: `retired(model);`
pub fn retired(model: *data.Model) void {
    const tab = model.tabs.activeSlot() orelse return;
    var panes = model.panes.iterateConst(model.tabs.location[tab].tab_id);
    while (panes.next()) |value| {
        if (value.history_intent != null) {
            model.panes_revision +%= 1;
            return;
        }
    }
}

/// Commits delivered geometry without confusing it with a new scroll gesture.
/// Example: `anchor(model, id, resolved_scroll);`
pub fn anchor(model: *data.Model, id: core.PaneId, scroll: f64) void {
    const value = findPane(model, id) orelse return;
    value.transcript_scroll = scroll;
    value.transcript_anchor_revision +%= 1;
    invalidate(model, id);
}

/// Fresh scroll input renews prefetch and invalidates an opposing request.
/// Example: `reverse(model, id, .newer);`
pub fn reverse(model: *data.Model, id: core.PaneId, direction: core.agent_history.Direction) void {
    const value = findPane(model, id) orelse return;
    const window = value.agent_history orelse return;
    if (window.retained) {
        return;
    }

    if (window.scan_remaining != data.AgentHistoryWindow.max_scan_pages) {
        window.scan_remaining = data.AgentHistoryWindow.max_scan_pages;
        invalidate(model, id);
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
    invalidate(model, id);
}

fn invalidate(model: *data.Model, id: core.PaneId) void {
    const tab = model.tabs.activeSlot() orelse return;
    if (model.panes.findInConst(model.tabs.location[tab].tab_id, id) != null) {
        model.panes_revision +%= 1;
    }
}

fn resolve(model: *data.Model, operation: data.AgentHistoryOperation) ?*data.Pane {
    const value = findPane(model, operation.owner.pane_id) orelse return null;
    if (value.attachment_generation != operation.owner.attachment_generation or value.pane_generation != operation.owner.pane_generation) {
        return null;
    }
    const window = value.agent_history orelse return null;
    return if (window.generation == operation.view_generation and window.pending != null) value else null;
}

fn findPane(model: *data.Model, id: core.PaneId) ?*data.Pane {
    const value = model.panes.find(id) orelse return null;
    return if (value.attached and value.kind == .agent) value else null;
}

fn ensureWindow(model: *data.Model, pane: *data.Pane) !?*data.AgentHistoryWindow {
    if (pane.agent_history) |existing| {
        return existing;
    }
    const live = pane.agent_thread orelse return null;
    try reserveWindow(model);
    const created = try pane.gpa.create(data.AgentHistoryWindow);
    pane.history_generation +%= 1;
    created.start(live, pane.history_generation);
    pane.agent_history = created;
    return created;
}

fn reserveWindow(model: *data.Model) !void {
    var count: usize = 0;
    var inactive: ?*data.Pane = null;
    const active = model.activeTabLocation();
    var panes = model.panes.iterate(null);
    while (panes.next()) |value| {
        if (value.agent_history != null) {
            count += 1;
            const visible = if (active) |location| value.location.tab_id == location.tab_id else false;
            if (!visible and !value.agent_history.?.retained) {
                inactive = value;
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
