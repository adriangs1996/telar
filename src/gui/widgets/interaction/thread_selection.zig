//! Native conversation selection shares delivered geometry with keyboard copy mode.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const GuiClient = @import("../../GuiClient.zig");
const Event = @import("../../input/event.zig").Event;
const Target = @import("Target.zig");
const Position = @import("ThreadTextPosition.zig");
const Geometry = @import("ThreadTextGeometry.zig");
const message_links = @import("message_links.zig");
const Selection = @import("ThreadSelection.zig");

/// Enters through the semantic action port, preserving configured bindings.
/// Example: `_ = thread_selection.enter(gui, pane_id);`
pub fn enter(gui: *GuiClient, pane_id: core.PaneId) bool {
    const target = transcript(gui, pane_id) orelse return false;
    const store = gui.widgets.thread_text orelse return false;
    if (!@import("../../input/PointerRouting.zig").geometryMatches(&gui.app) or gui.app.model.name_prompt.active() or gui.widgets.composer_menu.selector != null) {
        return false;
    }
    const at = store.maps.presented().hit(.{ .pane_id = pane_id, .point = .{ target.bounds.x + target.bounds.width, target.bounds.y + target.bounds.height - 1 } }) orelse return false;
    if (!valid(gui, at)) {
        return false;
    }
    const selection = &gui.widgets.thread_selection;
    gui.widgets.thread_scroll.cancel(pane_id);
    selection.restart(.{ .pane_id = pane_id, .attachment_generation = target.id.generation });
    selection.head = at;
    selection.keyboard = true;
    gui.widgets.cancelComposition();
    _ = gui.widgets.dispatcher.focus(target.id);
    gui.widgets.dispatcher.revision +%= 1;
    return true;
}

/// Example: `if (thread_selection.active(gui)) showCopyMode();`
pub fn active(gui: *const GuiClient) bool {
    return gui.widgets.thread_selection.keyboard;
}

/// Restores this reader's composer and defers releasing its pinned window.
/// Example: `_ = thread_selection.leave(gui);`
pub fn leave(gui: *GuiClient) bool {
    const selection = &gui.widgets.thread_selection;
    const owner = selection.owner orelse return false;
    selection.clear();
    for (gui.widgets.dispatcher.maps.presented().targets[0..gui.widgets.dispatcher.maps.presented().len]) |target| {
        if (target.action == .composer and target.action.composer == owner.pane_id and target.id.generation == owner.attachment_generation) {
            _ = gui.widgets.dispatcher.focus(target.id);
            break;
        }
    }
    gui.widgets.dispatcher.revision +%= 1;
    return true;
}

/// Validates ownership before freezing pages; no allocation occurs in input.
/// Example: `try thread_selection.prepare(gui);`
pub fn prepare(gui: *GuiClient) !void {
    const selection = &gui.widgets.thread_selection;
    if (selection.release) |owner| {
        client.agent_history.unfreeze(&gui.app, owner.pane_id, owner.attachment_generation);
        selection.release = null;
    }
    const owner = selection.owner orelse return;
    const pane = gui.app.model.agentPane(owner.pane_id);
    const tab = gui.app.model.activeTabModelConst();
    const focused = gui.widgets.dispatcher.focusedTarget();
    const current = focused != null and focused.?.action == .transcript and focused.?.action.transcript == owner.pane_id and gui.focused and pane != null and pane.?.attachment_generation == owner.attachment_generation and tab != null and tab.?.layout.focused() == owner.pane_id and !gui.app.model.name_prompt.active() and gui.widgets.composer_menu.selector == null;
    const head = selection.head;
    if (!current or head == null or !valid(gui, head.?)) {
        cancel(gui);
        if (selection.release) |released| {
            client.agent_history.unfreeze(&gui.app, released.pane_id, released.attachment_generation);
            selection.release = null;
        }
        return;
    }
    if (selection.retains(owner.pane_id) and !selection.frozen) {
        selection.frozen = client.agent_history.freeze(&gui.app, owner.pane_id, owner.attachment_generation) catch |err| {
            _ = leave(gui);
            try client.controllers.notifications.publishNow(&gui.app, .{ .level = .failure, .title = "Could not select messages", .message = @errorName(err) });
            return;
        };
        if (!selection.frozen) {
            _ = leave(gui);
            return;
        }
    } else if (!selection.retains(owner.pane_id) and selection.frozen) {
        client.agent_history.unfreeze(&gui.app, owner.pane_id, owner.attachment_generation);
        selection.frozen = false;
    }
    if (selection.dragging and selection.outside != 0) {
        const now = client.monotonic(gui.app.io);
        if (now >= selection.next_scroll_ns) {
            try scroll(gui, selection.outside);
            selection.next_scroll_ns = now + 30 * std.time.ns_per_ms;
        }
    }
}

/// Updates a retained drag after its newly scrolled geometry reaches the host.
/// Example: `thread_selection.delivered(gui);`
pub fn delivered(gui: *GuiClient) void {
    const selection = &gui.widgets.thread_selection;
    const owner = selection.owner orelse return;
    const store = gui.widgets.thread_text orelse return;
    if (selection.dragging or selection.pending_vertical != 0) {
        if (store.maps.presented().hit(.{ .pane_id = owner.pane_id, .point = selection.pointer })) |at| {
            if (valid(gui, at) and (selection.head == null or !selection.head.?.eql(at))) {
                selection.head = at;
                gui.widgets.dispatcher.revision +%= 1;
            }
        }
        selection.pending_vertical = 0;
    }
}

/// Routes only gestures and keys owned by the delivered conversation target.
/// Example: `if (try thread_selection.route(gui, event, decision)) return true;`
pub fn route(gui: *GuiClient, event: Event, decision: @import("Route.zig")) !bool {
    const selection = &gui.widgets.thread_selection;
    if (event == .focus and !event.focus) {
        cancel(gui);
        return false;
    }
    if (event == .pointer) {
        return pointer(gui, event.pointer, decision.target);
    }
    const target = decision.target orelse return false;
    if (target.action != .transcript or target.layer != 0 or gui.app.model.name_prompt.active()) {
        return false;
    }
    if (event == .key) {
        if (event.key.phase == .release) {
            return true;
        }
        try key(gui, target, event.key);
        return true;
    }
    if (event == .text) {
        if (event.text.phase != .release and event.text.physical != null and event.text.bytes.len == 1 and selection.keyboard) {
            try key(gui, target, .{ .code = .{ .char = .init(event.text.bytes) }, .phase = event.text.phase });
        }
        return true;
    }
    return event == .composition or event == .paste or event == .delete_surrounding;
}

fn pointer(gui: *GuiClient, event: @import("../../input/PointerEvent.zig"), target: ?Target) !bool {
    const selection = &gui.widgets.thread_selection;
    if (event.button != .left) {
        return false;
    }
    if (event.kind == .press) {
        const hit = target orelse {
            cancel(gui);
            return false;
        };
        const pane_id = switch (hit.action) {
            .transcript => |id| id,
            .message_link => |link| link.owner.pane_id,
            else => {
                cancel(gui);
                return false;
            },
        };
        const container = transcript(gui, pane_id) orelse return true;
        const store = gui.widgets.thread_text orelse return true;
        const at = store.maps.presented().hit(.{ .pane_id = pane_id, .point = .{ event.x, event.y } }) orelse return true;
        if (!valid(gui, at)) {
            return true;
        }
        const previous = if (event.mods & 1 != 0 and selection.owner != null and selection.owner.?.pane_id == pane_id) selection.anchor else null;
        gui.widgets.thread_scroll.cancel(pane_id);
        selection.restart(.{ .pane_id = pane_id, .attachment_generation = container.id.generation });
        selection.anchor = previous orelse at;
        selection.head = at;
        selection.dragging = true;
        if (hit.action == .message_link and event.mods == 0) {
            selection.pending_link = hit.action.message_link;
        }

        selection.pointer = .{ event.x, event.y };
        gui.widgets.cancelComposition();
        gui.widgets.dispatcher.captures[0] = container.id;
        _ = gui.widgets.dispatcher.focus(container.id);
        const model = gui.app.model.activeTabModel() orelse return true;
        _ = try client.controllers.view_interactions.apply(&gui.app, model, .{ .intent = .{ .focus_pane = pane_id }, .consumed = true });
        message_links.clear(gui);
        gui.widgets.dispatcher.revision +%= 1;
        return true;
    }
    if ((event.kind == .drag or event.kind == .release) and selection.dragging) {
        if (event.kind == .drag) {
            selection.pending_link = null;
        }

        const owner = selection.owner orelse return true;
        const container = transcript(gui, owner.pane_id) orelse {
            _ = leave(gui);
            return true;
        };
        const store = gui.widgets.thread_text orelse return true;
        selection.pointer = .{ event.x, event.y };
        if (store.maps.presented().hit(.{ .pane_id = owner.pane_id, .point = selection.pointer })) |at| {
            if (valid(gui, at)) {
                selection.head = at;
            }
        }
        selection.outside = if (event.y < container.bounds.y) 1 else if (event.y > container.bounds.y + container.bounds.height) -1 else 0;
        if (event.kind == .release) {
            selection.dragging = false;
            selection.outside = 0;
            const pending_link = selection.pending_link;
            selection.pending_link = null;
            if (pending_link) |link| {
                const hit = gui.widgets.dispatcher.maps.presented().at(selection.pointer);
                if (!selection.selected() and hit != null and hit.?.action == .message_link and std.meta.eql(hit.?.action.message_link, link)) {
                    try message_links.open(gui, link);
                }
            }
        }
        gui.widgets.dispatcher.revision +%= 1;
        return true;
    }
    return false;
}

fn key(gui: *GuiClient, target: Target, value: @import("../../input/KeyInput.zig")) !void {
    const selection = &gui.widgets.thread_selection;
    if (value.code == .escape) {
        _ = leave(gui);
        return;
    }
    if (value.code == .char) {
        const char = value.code.char;
        if (value.mods.super or value.mods.ctrl) {
            if (char.eql("c")) {
                if (value.phase == .press) {
                    copy(gui, false);
                }
                return;
            }
            if (char.eql("a")) {
                selectAll(gui, target);
                return;
            }
        }
    }
    if (value.code == .page_up or value.code == .page_down) {
        if (selection.keyboard) {
            if (value.mods.shift and selection.anchor == null) {
                selection.anchor = selection.head;
            } else if (!value.mods.shift and !selection.selecting) {
                selection.anchor = null;
            }
            const store = gui.widgets.thread_text orelse return;
            const area = if (selection.head) |head| locate(store.maps.presented(), head) orelse target.bounds else target.bounds;
            selection.pointer = .{ selection.preferred_x orelse area.x, area.y + area.height / 2 };
            selection.pending_vertical = if (value.code == .page_up) 1 else -1;
        }
        try scroll(gui, if (value.code == .page_up) 12 else -12);
        return;
    }
    if (!selection.keyboard) {
        return;
    }
    if (value.code == .enter) {
        if (value.phase == .press) {
            copy(gui, true);
        }
        return;
    }
    var code = value.code;
    if (code == .char) {
        const char = code.char;
        if (char.eql("q")) {
            _ = leave(gui);
            return;
        } else if (char.eql("y")) {
            if (value.phase == .press) {
                copy(gui, true);
            }
            return;
        } else if (char.eql("v") or char.eql(" ")) {
            selection.selecting = !selection.selecting;
            selection.anchor = if (selection.selecting) selection.head else null;
            gui.widgets.dispatcher.revision +%= 1;
            return;
        } else if (char.eql("h")) {
            code = .left;
        } else if (char.eql("l")) {
            code = .right;
        } else if (char.eql("j")) {
            code = .down;
        } else if (char.eql("k")) {
            code = .up;
        } else if (char.eql("0")) {
            code = .home;
        } else if (char.eql("$")) {
            code = .end;
        } else {
            return;
        }
    }
    const old = selection.head orelse return;
    if (value.mods.shift and selection.anchor == null) {
        selection.anchor = old;
    } else if (!value.mods.shift and !selection.selecting) {
        selection.anchor = null;
    }
    const store = gui.widgets.thread_text orelse return;
    const geometry = store.maps.presented();
    if (code == .left or code == .right) {
        selection.head = adjacent(geometry, old, code == .right) orelse old;
        selection.preferred_x = null;
    } else if (code == .up or code == .down or code == .home or code == .end) {
        const area = locate(geometry, old) orelse return;
        var point: [2]f64 = .{ selection.preferred_x orelse area.x, area.y + area.height / 2 };
        if (code == .home or code == .end) {
            point[0] = if (code == .home) target.bounds.x else target.bounds.x + target.bounds.width;
            selection.preferred_x = null;
        } else {
            selection.preferred_x = point[0];
            point[1] += if (code == .up) -area.height else area.height;
        }
        if (point[1] < target.bounds.y or point[1] >= target.bounds.y + target.bounds.height) {
            selection.pending_vertical = if (code == .up) 1 else -1;
            selection.pointer = point;
            try scroll(gui, selection.pending_vertical);
        } else if (geometry.hit(.{ .pane_id = target.action.transcript, .point = point })) |at| {
            selection.head = at;
        }
    }
    gui.widgets.dispatcher.revision +%= 1;
}

fn selectAll(gui: *GuiClient, target: Target) void {
    const store = gui.widgets.thread_text orelse return;
    const selection = &gui.widgets.thread_selection;
    selection.owner = .{ .pane_id = target.action.transcript, .attachment_generation = target.id.generation };
    var first: ?Position = null;
    var last: ?Position = null;
    for (store.maps.presented().rows[0..store.maps.presented().row_count]) |row| {
        if (row.owner.pane_id != target.action.transcript) {
            continue;
        }
        for ([_]bool{ true, false }) |metadata| {
            const len = if (metadata) row.detail_len else row.body_len;
            if (len == 0) {
                continue;
            }
            var at: Position = .{ .owner = row.owner, .order = row.order, .offset = if (metadata) row.detail_offset else row.owner.source_offset };
            at.owner.section = if (metadata) .metadata else .body;
            at.owner.source_offset = at.offset;
            if (first == null) {
                first = at;
            }
            at.offset += len;
            last = at;
        }
    }
    selection.anchor = first;
    selection.head = last;
    gui.widgets.dispatcher.revision +%= 1;
}

fn copy(gui: *GuiClient, exit_after: bool) void {
    const selection = &gui.widgets.thread_selection;
    if (!selection.selected() or selection.clipboard != null) {
        return;
    }
    const owner = selection.owner orelse return;
    const target = transcript(gui, owner.pane_id) orelse return;
    var bytes: [@import("../../input/event.zig").max_text_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    (@import("ThreadSelectionCopy.zig"){ .gui = gui, .range = selection.range().?, .writer = &writer }).write() catch |err| {
        selection.problem = if (err == error.WriteFailed) .copy_limit else if (err == error.SelectionGeometryLimit) .geometry_limit else .copy_failed;
        gui.widgets.dispatcher.revision +%= 1;
        return;
    };
    const request_owner: @import("../../host/Owner.zig") = .{ .target_id = target.id.target_id, .generation = target.id.generation };
    const request = gui.requestClipboardWriteOwned(request_owner, writer.buffered()) catch {
        selection.problem = .copy_failed;
        gui.widgets.dispatcher.revision +%= 1;
        return;
    };
    selection.clipboard = .{ .request_id = request, .owner = request_owner, .exit_after = exit_after, .range = selection.range().? };
    selection.problem = null;
}

/// Failure preserves the selection; exiting copy mode waits for host success.
/// Example: `thread_selection.copied(gui, result);`
pub fn copied(gui: *GuiClient, result: @import("../../input/ClipboardResult.zig")) void {
    const selection = &gui.widgets.thread_selection;
    const pending = selection.clipboard orelse return;
    if (pending.request_id != result.request_id or pending.owner.target_id != result.target_id or pending.owner.generation != result.generation) {
        return;
    }
    selection.clipboard = null;
    if (result.status == .success) {
        if (pending.exit_after) {
            const current = selection.range() orelse return;
            if (current[0].eql(pending.range[0]) and current[1].eql(pending.range[1])) {
                _ = leave(gui);
            }
        }
    } else {
        selection.problem = .copy_failed;
    }
    gui.widgets.dispatcher.revision +%= 1;
}

fn scroll(gui: *GuiClient, delta: i32) !void {
    const selection = &gui.widgets.thread_selection;
    const owner = selection.owner orelse return;
    const target = transcript(gui, owner.pane_id) orelse return;
    const pane = gui.app.model.agentPane(owner.pane_id) orelse return;
    const next = std.math.clamp(pane.transcript_scroll + @as(f64, @floatFromInt(delta)), 0, target.scroll_limit);
    selection.blocked_edge = next == pane.transcript_scroll;
    try client.agent_threads.scroll(&gui.app, owner.pane_id, next - pane.transcript_scroll);
}

fn valid(gui: *const GuiClient, at: Position) bool {
    const pane = gui.app.model.agentPane(at.owner.pane_id) orelse return false;
    if (pane.attachment_generation != at.owner.attachment_generation) {
        return false;
    }
    const snapshot = pane.threadItemSource(at.owner.item_identity) orelse return false;
    return snapshot.pane_generation == at.owner.pane_generation and snapshot.revision == at.owner.snapshot_revision;
}

fn transcript(gui: *const GuiClient, pane_id: core.PaneId) ?Target {
    const pane = gui.app.model.agentPane(pane_id) orelse return null;
    for (gui.widgets.dispatcher.maps.presented().targets[0..gui.widgets.dispatcher.maps.presented().len]) |target| {
        if (target.action == .transcript and target.action.transcript == pane_id and target.id.generation == pane.attachment_generation and target.focusable) {
            return target;
        }
    }
    return null;
}

fn adjacent(geometry: *const Geometry, current: Position, forward: bool) ?Position {
    var result: ?Position = null;
    for (geometry.fragments[0..geometry.fragment_count]) |fragment| {
        for (geometry.carets[fragment.caret_start..][0..fragment.caret_count], 0..) |_, index| {
            const at = geometry.position(fragment, index);
            if (at.owner.pane_id != current.owner.pane_id or (if (forward) !current.before(at) else !at.before(current))) {
                continue;
            }
            if (result == null or (if (forward) at.before(result.?) else result.?.before(at))) {
                result = at;
            }
        }
    }
    return result;
}

fn locate(geometry: *const Geometry, current: Position) ?@import("../../render/Rect.zig") {
    for (geometry.fragments[0..geometry.fragment_count]) |fragment| {
        for (geometry.carets[fragment.caret_start..][0..fragment.caret_count], 0..) |caret, index| {
            if (current.eql(geometry.position(fragment, index))) {
                return .{ .x = fragment.bounds.x + caret.x, .y = fragment.bounds.y, .width = 1, .height = fragment.bounds.height };
            }
        }
    }
    return null;
}

/// External focus changes cancel ownership without stealing the new focus.
/// Example: `thread_selection.cancel(gui);`
pub fn cancel(gui: *GuiClient) void {
    if (gui.widgets.thread_selection.owner != null) {
        gui.widgets.thread_selection.clear();
        gui.widgets.dispatcher.revision +%= 1;
    }
}
