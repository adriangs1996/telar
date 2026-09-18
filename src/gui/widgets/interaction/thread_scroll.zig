//! Native motion advances before projection; drawing and hit testing share the
//! same model offset. Page delivery rebases the trajectory without an impulse.
const client = @import("telar-client");
const GuiClient = @import("../../GuiClient.zig");
const Target = @import("Target.zig");
const Event = @import("../../input/ScrollEvent.zig");
const Entry = @import("ThreadScrollMotion.zig");

/// Keeps a precise gesture and its native momentum on the original transcript.
/// Example: `if (try thread_scroll.captured(gui, event)) return true;`
pub fn captured(gui: *GuiClient, event: Event) !bool {
    const motions = &gui.widgets.thread_scroll;
    if (!event.precise or event.phase == .begin or (event.phase == .none and event.momentum == .none)) {
        motions.gesture = null;
        motions.gesture_pane = null;
        motions.foreign_gesture = event.phase == .begin;
        motions.discarded_gesture = false;
        return false;
    }

    if (motions.discarded_gesture) {
        return true;
    }

    const owner = motions.gesture orelse return false;
    const target = gui.widgets.dispatcher.maps.presented().find(owner) orelse return true;
    if (!@import("routing.zig").eligible(gui, target)) {
        return true;
    }

    try input(gui, target, event);
    return true;
}

/// Routes physical motion independently of the host that supplied the gesture.
/// Example: `try thread_scroll.input(gui, transcript_target, event);`
pub fn input(gui: *GuiClient, target: Target, event: Event) !void {
    if (target.action != .transcript or !gui.focused) {
        return;
    }

    const pane_id = target.action.transcript;
    const pane = gui.app.model.agentPane(pane_id) orelse return;
    const motions = &gui.widgets.thread_scroll;
    const now_ns = client.monotonic(gui.app.io);
    const cancelled = event.phase == .cancel or event.momentum == .cancel;
    if (event.precise and event.phase != .begin and motions.discarded_gesture) {
        return;
    }
    if (event.precise and event.phase != .none and event.phase != .begin and motions.foreign_gesture) {
        return;
    }
    if (event.precise and event.momentum != .none and motions.foreign_gesture) {
        return;
    }

    const entry = motions.obtain(pane, now_ns) orelse return;
    if (event.precise and (event.phase != .none or event.momentum != .none)) {
        motions.gesture = target.id;
        motions.gesture_pane = pane_id;
        motions.foreign_gesture = false;
        motions.discarded_gesture = false;
    }
    if (cancelled or event.momentum == .end or (event.kinetic and event.phase == .end)) {
        motions.gesture = null;
        motions.gesture_pane = null;
        motions.foreign_gesture = true;
        motions.discarded_gesture = true;
    }

    entry.geometry(target, now_ns);
    var normalized = event;
    normalized.delta_y = -event.delta_y * (if (event.precise) @as(f64, 1) else entry.step);
    if (!cancelled and normalized.delta_y != 0) {
        gui.widgets.thread_anchor.cancel(pane_id);
        @import("message_links.zig").clear(gui);
    }
    entry.input(normalized, now_ns);
    try apply(gui, entry);
    gui.widgets.dispatcher.revision +%= 1;

    if (!cancelled and normalized.delta_y != 0) {
        navigate(gui, entry, normalized.delta_y);
    }
}

/// Uses elapsed monotonic time once, before borrowing the model for drawing.
/// Example: `try thread_scroll.advance(gui, now_ns);`
pub fn advance(gui: *GuiClient, now_ns: u64) !void {
    const motions = &gui.widgets.thread_scroll;
    if (!gui.focused or gui.app.model.name_prompt.active() or gui.widgets.image_preview != null or gui.widgets.composer_menu.selector != null) {
        motions.clear();
        return;
    }

    const model = gui.app.model.activeTabModelConst() orelse {
        motions.clear();
        return;
    };
    for (motions.entries[0..motions.len]) |*entry| {
        const pane = model.findConst(entry.key.pane_id) orelse continue;
        if (!pane.attached or pane.kind != .agent or pane.attachment_generation != entry.key.pane_generation) {
            continue;
        }

        entry.synchronize(pane, now_ns);
        const previous = entry.applied;
        entry.advance(now_ns);
        try apply(gui, entry);
        if (previous > 0 and entry.applied == 0 and !entry.has_newer and !gui.widgets.thread_selection.retains(pane.id) and !reviewing(gui, pane.id)) {
            client.agent_history.navigate(&gui.app, pane.id, .newer);
        }
    }
}

/// Adopts only successfully presented limits and committed page-anchor changes.
/// Example: `thread_scroll.delivered(gui);`
pub fn delivered(gui: *GuiClient) void {
    const motions = &gui.widgets.thread_scroll;
    const registry = gui.widgets.dispatcher.maps.presented();
    motions.retain(registry);
    for (registry.targets[0..registry.len]) |target| {
        if (target.action != .transcript) {
            continue;
        }

        const entry = motions.find(.{ .pane_id = target.action.transcript, .pane_generation = target.id.generation }) orelse continue;
        const pane = gui.app.model.agentPane(entry.key.pane_id) orelse continue;
        if (pane.attachment_generation != entry.key.pane_generation) {
            continue;
        }

        entry.synchronize(pane, gui.chrome.now_ns);
        entry.geometry(target, gui.chrome.now_ns);
        motions.schedule(target, &gui.chrome.animation);
    }
}

fn apply(gui: *GuiClient, entry: *Entry) !void {
    if (!entry.geometry_ready) {
        return;
    }

    const pane = gui.app.model.agentPane(entry.key.pane_id) orelse return;
    const next = entry.motion.spring.position / entry.step;
    try client.agent_threads.scroll(&gui.app, pane.id, next - pane.transcript_scroll);
    entry.applied = pane.transcript_scroll;
}

fn navigate(gui: *GuiClient, entry: *const Entry, delta: f64) void {
    const pane_id = entry.key.pane_id;
    const next = entry.applied;
    if (gui.widgets.thread_selection.retains(pane_id)) {
        gui.widgets.thread_selection.blocked_edge = (delta > 0 and next == entry.limit) or (delta < 0 and next == 0);
        return;
    }

    if (reviewing(gui, pane_id)) {
        return;
    }

    client.agent_history.reverse(&gui.app, pane_id, if (delta > 0) .older else .newer);
    if (!entry.geometry_ready) {
        return;
    }

    if (delta > 0 and next == entry.limit) {
        client.agent_history.navigate(&gui.app, pane_id, .older);
    } else if (delta < 0 and next == 0) {
        client.agent_history.navigate(&gui.app, pane_id, .newer);
    }
}

fn reviewing(gui: *const GuiClient, pane_id: @import("telar-core").PaneId) bool {
    const review = gui.widgets.approval_review orelse return false;
    const model = gui.app.model.activeTabModelConst() orelse return false;
    const thread = client.ThreadView.capture(model, null, pane_id) orelse return false;
    return review.request(thread) != null;
}
