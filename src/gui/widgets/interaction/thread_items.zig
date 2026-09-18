//! Conversation controls resolve against the live attachment and stable item
//! identity, even when input still refers to an older delivered frame.
const GuiClient = @import("../../GuiClient.zig");
const Target = @import("Target.zig");
const core = @import("telar-core");

/// Example: `if (!thread_items.eligible(gui, target)) return;`
pub fn eligible(gui: *const GuiClient, target: Target) bool {
    const thread = snapshot(gui, target) orelse return false;
    return thread.findItem(target.action.thread_item.identity) != null;
}

/// Example: `try thread_items.activate(gui, target);`
pub fn activate(gui: *GuiClient, target: Target) !void {
    const thread = snapshot(gui, target) orelse return;
    const control = target.action.thread_item;
    const item = thread.findItem(control.identity) orelse return;
    switch (control.operation) {
        .toggle, .toggle_work => {
            const pane = gui.app.model.agentPane(control.pane_id) orelse return;
            gui.widgets.thread_scroll.cancel(pane.id);
            gui.widgets.thread_anchor.capture(.{ .control = control, .baseline = pane.transcript_scroll, .offset = target.thread_header_offset });
            gui.widgets.thread_expansions.toggle(control);
            if (control.operation == .toggle_work and gui.widgets.threadExpanded(control)) {
                @import("telar-client").agent_history.revealWork(&gui.app, pane.id, control.source_key);
            }
            gui.widgets.dispatcher.revision +%= 1;
        },
        .copy => {
            for (&gui.widgets.pending_thread_copies) |*slot| {
                if (slot.* != null) {
                    continue;
                }

                const request_id = gui.requestClipboardWriteOwned(.{ .target_id = target.id.target_id, .generation = target.id.generation }, item.text(thread)) catch return;
                slot.* = .{ .request_id = request_id, .owner = target.id, .control = control };
                return;
            }
        },
    }
}

/// Commits only the navigation used by a successfully delivered frame.
/// Example: `try thread_items.delivered(gui);`
pub fn delivered(gui: *GuiClient) !void {
    const anchor = &gui.widgets.thread_anchor;
    const resolution = anchor.prepared orelse return;
    anchor.prepared = null;
    if (!anchor.current(resolution)) {
        return;
    }

    anchor.pending = null;
    const request = resolution.request;
    const pane = gui.app.model.agentPane(request.control.pane_id) orelse return;
    if (!pane.attached or pane.attachment_generation != request.control.attachment_generation or pane.transcript_scroll != request.baseline) {
        return;
    }

    const thread = pane.threadItemSource(request.control.identity) orelse return;
    if (thread.findItem(request.control.identity) == null) {
        return;
    }

    try @import("telar-client").agent_threads.scroll(&gui.app, pane.id, resolution.scroll - request.baseline);
}

/// Native failure never displays a successful copy. Example: `thread_items.copied(gui, result);`
pub fn copied(gui: *GuiClient, result: @import("../../input/ClipboardResult.zig")) void {
    const id: @import("Id.zig") = .{ .target_id = result.target_id, .generation = result.generation };
    for (&gui.widgets.pending_thread_copies) |*slot| {
        const pending = slot.* orelse continue;
        if (pending.request_id != result.request_id or !pending.owner.eql(id)) {
            continue;
        }

        slot.* = null;
        const target = gui.widgets.dispatcher.maps.presented().find(id) orelse return;
        if (result.status != .success or !eligible(gui, target)) {
            return;
        }

        gui.widgets.copied_item = pending.control;
        gui.widgets.copied_until_ns = @import("telar-client").monotonic(gui.app.io) +| 2 * @import("std").time.ns_per_s;
        gui.widgets.dispatcher.revision +%= 1;
        return;
    }
}

fn snapshot(gui: *const GuiClient, target: Target) ?*const core.AgentThreadSnapshot {
    if (target.action != .thread_item or target.layer != 0 or gui.app.model.name_prompt.active()) {
        return null;
    }

    const control = target.action.thread_item;
    const model = gui.app.model.activeTabModelConst() orelse return null;
    const pane = model.findConst(control.pane_id) orelse return null;
    if (!pane.attached or pane.kind != .agent or pane.attachment_generation != control.attachment_generation or target.id.generation != control.attachment_generation or control.identity == 0) {
        return null;
    }

    return pane.threadItemSource(control.identity);
}
